# The "back in a moment" responder for a database cutover (scripts/move-db, docs: Operations → Scale a site out): during the brief
# cutoff, the project's API Service is pointed at this pod, which answers every request with 503 and Retry-After.
# Created just before the cutoff and deleted after it.
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${NAME}
  namespace: ${NS}
  labels: { app.kubernetes.io/part-of: ${PART_OF}, app.kubernetes.io/managed-by: anvil, anvil/tier: app }
data:
  default.conf: |
    server {
${LISTEN}
        default_type application/json;
        add_header Retry-After 15 always;
        add_header Cache-Control "no-store" always;
        location / { return 503 '{"status":"maintenance","message":"Back in a moment"}\n'; }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${NAME}
  namespace: ${NS}
  labels: { app.kubernetes.io/name: ${NAME}, app.kubernetes.io/part-of: ${PART_OF}, app.kubernetes.io/managed-by: anvil, anvil/tier: app, app.kubernetes.io/component: web }
spec:
  replicas: 1
  selector: { matchLabels: { app: ${NAME} } }
  template:
    metadata: { labels: { app: ${NAME}, app.kubernetes.io/name: ${NAME}, app.kubernetes.io/part-of: ${PART_OF}, app.kubernetes.io/component: web } }
    spec:
      enableServiceLinks: false
      securityContext: { runAsUser: ${UID}, runAsGroup: ${UID} }
      containers:
        - name: nginx
          image: nginxinc/nginx-unprivileged:1.30-alpine
          securityContext: { allowPrivilegeEscalation: false }
          ports: [${PORTS}]
          resources: { requests: { cpu: 10m, memory: 8Mi }, limits: { memory: 32Mi } }
          readinessProbe: { tcpSocket: { port: ${FIRST_PORT} }, periodSeconds: 2 }
          livenessProbe: { tcpSocket: { port: ${FIRST_PORT} }, initialDelaySeconds: 120, periodSeconds: 30, timeoutSeconds: 10, failureThreshold: 5 }
          volumeMounts: [{ name: conf, mountPath: /etc/nginx/conf.d }]
      volumes: [{ name: conf, configMap: { name: ${NAME} } }]
