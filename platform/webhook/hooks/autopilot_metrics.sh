#!/bin/bash

# GET /autopilot_metrics?code=<STATUS_CODE>: Prometheus metrics from the autopilot's last report (job "autopilot").
# Nothing before its first report, so MacOffline (time() - autopilot_last_heartbeat_seconds > 600) can't fire early.

[ -n "${STATUS_CODE:-}" ] && [ "${code:-}" = "$STATUS_CODE" ] || exit 1
S=/locks/autopilot/state.json
[ -s "$S" ] || exit 0
jq -r '
  def ts: if . == null or . == "" then 0 else (sub("\\.[0-9]+"; "") | sub("Z$"; "") | strptime("%Y-%m-%dT%H:%M:%S") | mktime) end;
  "# TYPE autopilot_last_heartbeat_seconds gauge", "autopilot_last_heartbeat_seconds \(.received)",
  "# TYPE autopilot_state gauge",
  (. as $s | ("idle","running","gave_up","paused") | "autopilot_state{state=\"\(.)\"} \(if $s.state == . then 1 else 0 end)"),
  "# TYPE autopilot_paused_until_seconds gauge", "autopilot_paused_until_seconds \(.paused_until | ts)",
  "# TYPE autopilot_runs_today gauge", "autopilot_runs_today \(.runs_today // 0)",
  "# TYPE autopilot_runs_total gauge", "autopilot_runs_total \(.runs_total // 0)",
  "# TYPE autopilot_last_run_finished_seconds gauge", "autopilot_last_run_finished_seconds \(.last_run.finished | ts)",
  "# TYPE autopilot_last_run_result gauge",
  (. as $s | ("fixed","gave_up","error","timeout") | "autopilot_last_run_result{result=\"\(.)\"} \(if ($s.last_run.result // "") == . then 1 else 0 end)")' "$S"
