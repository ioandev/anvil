#!/bin/bash

# GET /cluster?code=<STATUS_CODE> -> 200 only if, according to Prometheus (alerting-prometheus):
#   - every probed public URL answers (probe_success, job sites; down = over half of the last 5 minutes of probes
#     failed, so a single failed probe doesn't turn it red), and
#   - every Deployment/StatefulSet has all its copies ready, and no pod is stuck unable to start
#     (kube-state-metrics; wrong for the last 5 minutes, so a normal rollout doesn't flap it, and only things
#     that still exist, so a deleted workload clears at once), ignoring work in progress like the alert rules:
#     workloads created/changed and pods started in the last 10 minutes, and sites whose namespace had such a change,
# else 500 with the problems, one per line. Also 500 if Prometheus can't be asked (blind is not healthy).
# Part of /overall. Without the right code: a bare 500. (Changing this file: `node.sh deploy webhook` restarts the pod itself.)

# Only callers with ?code=<STATUS_CODE> learn anything: everyone else gets a bare 500.
[ -n "${STATUS_CODE:-}" ] && [ "${code:-}" = "$STATUS_CODE" ] || exit 1

PROM=http://alerting-prometheus.alerting:9090

# query <promql> <jq expression turning each result into a line>
query() {
  local out
  out=$(curl -sf -m 8 --get "$PROM/api/v1/query" --data-urlencode "query=$1") || return 2
  echo "$out" | jq -r "if .status == \"success\" then .data.result[] | $2 else error(\"bad answer\") end" || return 2
}

# Work in progress (changed in the last 10 minutes) is skipped, like the alert rules. &strict=1 skips nothing: the
# autopilot uses it to check its own fix (its restart/rollback is a "recent change" too, which would hide the result).
if [ "${strict:-}" = 1 ]; then XS=""; XD=""; XST=""; XP=""
else
  XS=' unless on (namespace) (max by (namespace) ((time() - kube_deployment_created < 600) or (changes(kube_deployment_metadata_generation[10m]) > 0)))'
  XD=' unless on (namespace, deployment) ((time() - kube_deployment_created < 600) or (changes(kube_deployment_metadata_generation[10m]) > 0))'
  XST=' unless on (namespace, statefulset) ((time() - kube_statefulset_created < 600) or (changes(kube_statefulset_metadata_generation[10m]) > 0))'
  XP=' unless on (namespace, pod) (time() - kube_pod_created < 600)'
fi

problems=()
add() { while IFS= read -r l; do [ -n "$l" ] && problems+=("$l"); done; }

# A site is down here when more than half of its last 5 minutes of probes failed (about 2.5 minutes of failure).
# "Failed at least once in 5 minutes" kept /cluster and /overall red for 5 minutes after a single failed probe and
# started the autopilot for nothing (on the original server, 2026-11-07).
r=$(query '(avg_over_time(probe_success{job="sites"}[5m]) < 0.5)'"$XS" '"down: \(.metric.instance)"') || { echo "prometheus not answering: can't check sites or pods"; exit 1; }
add <<< "$r"
r=$(query '(min_over_time((kube_deployment_spec_replicas - kube_deployment_status_replicas_available)[5m:30s]) > 0) and on (namespace, deployment) kube_deployment_spec_replicas'"$XD" '"not ready: \(.metric.namespace)/\(.metric.deployment)"') || { echo "prometheus query failed"; exit 1; }
add <<< "$r"
r=$(query '(min_over_time((kube_statefulset_replicas - kube_statefulset_status_replicas_ready)[5m:30s]) > 0) and on (namespace, statefulset) kube_statefulset_replicas'"$XST" '"not ready: \(.metric.namespace)/\(.metric.statefulset)"') || { echo "prometheus query failed"; exit 1; }
add <<< "$r"
r=$(query '(min_over_time(kube_pod_container_status_waiting_reason{reason=~"CreateContainerConfigError|CreateContainerError|ImagePullBackOff|ErrImagePull|InvalidImageName|CrashLoopBackOff|RunContainerError"}[5m]) == 1) and on (namespace, pod) kube_pod_info'"$XP" '"stuck: \(.metric.namespace)/\(.metric.pod) (\(.metric.reason))"') || { echo "prometheus query failed"; exit 1; }
add <<< "$r"
# kube-state-metrics missing would make the checks above pass silently.
r=$(query 'absent(kube_deployment_spec_replicas)' '"kube-state-metrics not reporting: pods unchecked"') || { echo "prometheus query failed"; exit 1; }
add <<< "$r"

if [ "${#problems[@]}" -gt 0 ]; then
  echo "${#problems[@]} problem(s): $(IFS=';'; echo "${problems[*]}" | sed 's/;/; /g')"
  exit 1
fi
sites=$(query 'count(probe_success{job="sites"})' '.value[1]' 2>/dev/null)
pods=$(query 'count(kube_pod_status_phase{phase="Running"} == 1)' '.value[1]' 2>/dev/null)
echo "ok: ${sites:-?} URLs answering, ${pods:-?} pods running, nothing stuck"
exit 0
