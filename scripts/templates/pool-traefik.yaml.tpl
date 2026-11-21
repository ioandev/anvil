# Direct mode for pool ${POOL} (scripts/pool direct ${POOL} on|off, docs/scale-out-runbook.md): a second Traefik on
# the pool node, so Cloudflare can fetch the pool's sites from the pool itself instead of through the server.
# Same version and settings as k3s's Traefik on the server (it reads the same Ingresses, routes, middlewares, the
# Origin CA certificates in the default TLSStore and the default TLSOption that requires our Authenticated Origin
# Pulls client certificate), on the node's ports 443/80 (hostPort; the pool's firewall opens them to Cloudflare's
# ranges only, and only while direct mode is on). It doesn't publish Ingress status (the server's Traefik does).
# Visitors' addresses: Cloudflare connects to this pod directly (no ServiceLB hop), so X-Forwarded-For has one hop
# fewer than through the server; apps that read CF-Connecting-IP (rule 7) see no difference.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: traefik-pool-${POOL}
  namespace: kube-system
  labels: { app.kubernetes.io/name: traefik-pool-${POOL}, app.kubernetes.io/part-of: kube-system, app.kubernetes.io/managed-by: anvil, anvil/tier: platform, app.kubernetes.io/component: web }
spec:
  replicas: 1
  strategy: { type: Recreate }   # it holds the node's ports 80/443
  selector: { matchLabels: { app: traefik-pool-${POOL} } }
  template:
    metadata: { labels: { app: traefik-pool-${POOL}, app.kubernetes.io/name: traefik-pool-${POOL}, app.kubernetes.io/part-of: kube-system, app.kubernetes.io/component: web } }
    spec:
      enableServiceLinks: false
      serviceAccountName: traefik
      automountServiceAccountToken: true   # k3s's traefik ServiceAccount turns automount off (its chart mounts the token itself)
      nodeSelector: { anvil/pool: ${POOL} }
      tolerations: [{ key: anvil/dedicated, operator: Equal, value: ${POOL}, effect: NoSchedule }]
      securityContext: { runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532 }
      terminationGracePeriodSeconds: 30
      containers:
        - name: traefik
          image: ${IMAGE}
          args:
            - --entryPoints.metrics.address=:9100/tcp
            - --entryPoints.traefik.address=:8080/tcp
            - --entryPoints.web.address=:8000/tcp
            - --entryPoints.websecure.address=:8443/tcp
            - --ping=true
            - --metrics.prometheus=true
            - --metrics.prometheus.entrypoint=metrics
            - --providers.kubernetescrd
            - --providers.kubernetescrd.allowEmptyServices=true
            - --providers.kubernetesingress
            - --providers.kubernetesingress.allowEmptyServices=true
            - --entryPoints.websecure.http.tls=true
            - --entryPoints.websecure.forwardedHeaders.trustedIPs=${TRUSTED}
            - --log.level=INFO
          ports:
            - { name: web, containerPort: 8000, hostPort: 80, protocol: TCP }
            - { name: websecure, containerPort: 8443, hostPort: 443, protocol: TCP }
            - { name: traefik, containerPort: 8080, protocol: TCP }
            - { name: metrics, containerPort: 9100, protocol: TCP }
          readinessProbe: { httpGet: { path: /ping, port: 8080 }, periodSeconds: 5 }
          livenessProbe: { httpGet: { path: /ping, port: 8080 }, initialDelaySeconds: 120, periodSeconds: 30, timeoutSeconds: 10, failureThreshold: 5 }
          resources: { requests: { cpu: 500m, memory: 128Mi }, limits: { memory: 1536Mi } }   # 512Mi was OOMKilled at ~1,000 req/s on a CPU-starved node (ceiling run 6)
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] } }
          volumeMounts: [{ name: tmp, mountPath: /tmp }]
      volumes: [{ name: tmp, emptyDir: {} }]
