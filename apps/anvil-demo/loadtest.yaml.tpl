# The demo's load-test copy (scripts/loadtest anvil-demo up|seed|run|down): the demo app with production's image, its
# OWN MariaDB filled with generated data (apps/anvil-demo/loadtest-seed.sql), on the demo pool, behind a password,
# never indexed. Nothing here touches atlas or the real demo. Exists only during a test.
# Placeholders filled by scripts/loadtest (written $-brace-NAME-brace in the body): LT_NS, LT_HOST, LT_PLACEMENT,
# LT_IMAGE, LT_MARIADB_IMAGE, LT_WEB_REPLICAS; the ANVIL_* ones as everywhere. Secrets made by the script: <ns>-db (root), atlas-db (the app's login,
# same keys as the real one), anvil-demo (ADMIN_TOKEN), <ns>-auth (basic auth, one key), <ns>-password.
# UIDs: 6010 MariaDB, 6011 web, 6012 worker (sites.yaml anvil-demo-loadtest).
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: ${LT_NS}-mariadb
  namespace: ${LT_NS}
  labels: { app.kubernetes.io/name: ${LT_NS}-mariadb, app.kubernetes.io/part-of: ${LT_NS}, app.kubernetes.io/managed-by: anvil, anvil/tier: app, app.kubernetes.io/component: database }
spec:
  serviceName: ${LT_NS}-mariadb
  replicas: 1
  selector: { matchLabels: { app: ${LT_NS}-mariadb } }
  template:
    metadata: { labels: { app: ${LT_NS}-mariadb, app.kubernetes.io/name: ${LT_NS}-mariadb, app.kubernetes.io/part-of: ${LT_NS}, app.kubernetes.io/component: database } }
    spec:
      enableServiceLinks: false
${LT_PLACEMENT}
      securityContext: { runAsUser: 6010, runAsGroup: 6010, fsGroup: 6010 }
      containers:
        - name: mariadb
          image: ${LT_MARIADB_IMAGE}
          securityContext: { allowPrivilegeEscalation: false }
          args: [--character-set-server=utf8mb4, --collation-server=utf8mb4_unicode_ci, --innodb-buffer-pool-size=512M,
                 --max-connections=500, --performance-schema=OFF, --skip-log-bin,
                 # CAPACITY.md: look at the slow queries under load (kubectl exec ... -- tail /var/lib/mysql/slow.log)
                 --slow-query-log=1, --slow-query-log-file=/var/lib/mysql/slow.log, --long-query-time=0.2]
          env:
            - { name: MARIADB_ROOT_PASSWORD, valueFrom: { secretKeyRef: { name: ${LT_NS}-db, key: MARIADB_ROOT_PASSWORD } } }
            - { name: MARIADB_DATABASE, value: anvil_demo }
            - { name: MARIADB_USER, value: anvil_demo_rw }
            - { name: MARIADB_PASSWORD, valueFrom: { secretKeyRef: { name: atlas-db, key: DB_PASSWORD } } }
          ports: [{ name: mysql, containerPort: 3306 }]
          resources: { requests: { cpu: 200m, memory: 768Mi }, limits: { memory: 1536Mi } }
          readinessProbe: { exec: { command: ["healthcheck.sh", "--connect", "--innodb_initialized"] }, periodSeconds: 10 }
          livenessProbe: { exec: { command: ["healthcheck.sh", "--connect", "--innodb_initialized"] }, initialDelaySeconds: 120, periodSeconds: 30, timeoutSeconds: 10, failureThreshold: 5 }
          volumeMounts: [{ name: data, mountPath: /var/lib/mysql }]
  volumeClaimTemplates:
    - metadata: { name: data }
      spec: { accessModes: [ReadWriteOnce], storageClassName: local-path, resources: { requests: { storage: 5Gi } } }
---
apiVersion: v1
kind: Service
metadata: { name: ${LT_NS}-mariadb, namespace: ${LT_NS}, labels: { app.kubernetes.io/part-of: ${LT_NS}, app.kubernetes.io/managed-by: anvil, anvil/tier: app } }
spec:
  selector: { app: ${LT_NS}-mariadb }
  ports: [{ name: mysql, port: 3306 }]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${LT_NS}-web
  namespace: ${LT_NS}
  labels: { app.kubernetes.io/name: ${LT_NS}-web, app.kubernetes.io/part-of: ${LT_NS}, app.kubernetes.io/managed-by: anvil, anvil/tier: app, app.kubernetes.io/component: web }
spec:
  replicas: ${LT_WEB_REPLICAS}
  strategy: { type: RollingUpdate, rollingUpdate: { maxSurge: 1, maxUnavailable: 0 } }
  selector: { matchLabels: { app: ${LT_NS}-web } }
  template:
    metadata: { labels: { app: ${LT_NS}-web, app.kubernetes.io/name: ${LT_NS}-web, app.kubernetes.io/part-of: ${LT_NS}, app.kubernetes.io/component: web } }
    spec:
      enableServiceLinks: false
      automountServiceAccountToken: false
${LT_PLACEMENT}
      terminationGracePeriodSeconds: 30
      securityContext: { runAsUser: 6011, runAsGroup: 6011, runAsNonRoot: true, seccompProfile: { type: RuntimeDefault } }
      containers:
        - name: web
          image: ${LT_IMAGE}
          ports: [{ name: http, containerPort: 8080 }, { name: metrics, containerPort: 9090 }]
          envFrom: [{ secretRef: { name: atlas-db } }]
          env:
            - { name: ADMIN_TOKEN, valueFrom: { secretKeyRef: { name: anvil-demo, key: ADMIN_TOKEN } } }
            - { name: PORT, value: "8080" }
            - { name: METRICS_PORT, value: "9090" }
            - { name: PEERS_HOST, value: "${LT_NS}-web.${LT_NS}.svc.cluster.local" }
            - { name: WORKER_ADMIN_URL, value: "http://${LT_NS}-worker.${LT_NS}.svc:8081" }
            - { name: POD_IP, valueFrom: { fieldRef: { fieldPath: status.podIP } } }
            # Every k6 request comes from one machine (one IP): the per-visitor limit would measure itself, not the app.
            - { name: RATE_LIMIT_MAX, value: "1000000" }
            - { name: RATE_LIMIT_WINDOW_SECONDS, value: "60" }
            - { name: NODE_OPTIONS, value: "--max-old-space-size=96" }
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
          resources: { requests: { cpu: 100m, memory: 64Mi }, limits: { memory: 192Mi } }
          volumeMounts: [{ name: tmp, mountPath: /tmp }]
          lifecycle: { preStop: { sleep: { seconds: 5 } } }
          readinessProbe: { tcpSocket: { port: http }, periodSeconds: 2 }   # port check: a busy pod stays in service
          livenessProbe: { httpGet: { path: /healthz, port: http }, initialDelaySeconds: 120, periodSeconds: 30, timeoutSeconds: 10, failureThreshold: 5 }
      volumes: [{ name: tmp, emptyDir: { sizeLimit: 16Mi } }]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${LT_NS}-worker
  namespace: ${LT_NS}
  labels: { app.kubernetes.io/name: ${LT_NS}-worker, app.kubernetes.io/part-of: ${LT_NS}, app.kubernetes.io/managed-by: anvil, anvil/tier: app, app.kubernetes.io/component: worker }
spec:
  replicas: 1
  strategy: { type: Recreate }
  selector: { matchLabels: { app: ${LT_NS}-worker } }
  template:
    metadata: { labels: { app: ${LT_NS}-worker, app.kubernetes.io/name: ${LT_NS}-worker, app.kubernetes.io/part-of: ${LT_NS}, app.kubernetes.io/component: worker } }
    spec:
      enableServiceLinks: false
      automountServiceAccountToken: false
${LT_PLACEMENT}
      securityContext: { runAsUser: 6012, runAsGroup: 6012, runAsNonRoot: true, seccompProfile: { type: RuntimeDefault } }
      containers:
        - name: worker
          image: ${LT_IMAGE}
          args: ["dist/worker.js"]
          ports: [{ name: http, containerPort: 8081 }]
          envFrom: [{ secretRef: { name: atlas-db } }]
          env:
            - { name: ADMIN_TOKEN, valueFrom: { secretKeyRef: { name: anvil-demo, key: ADMIN_TOKEN } } }
            - { name: WORKER_PORT, value: "8081" }
            - { name: WORKER_INTERVAL_SECONDS, value: "5" }
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
          resources: { requests: { cpu: 10m, memory: 48Mi }, limits: { memory: 128Mi } }
          volumeMounts: [{ name: tmp, mountPath: /tmp }]
          readinessProbe: { tcpSocket: { port: http }, periodSeconds: 10 }
          livenessProbe: { httpGet: { path: /healthz, port: http }, initialDelaySeconds: 120, periodSeconds: 30, timeoutSeconds: 10, failureThreshold: 5 }
      volumes: [{ name: tmp, emptyDir: { sizeLimit: 16Mi } }]
---
apiVersion: v1
kind: Service
metadata: { name: ${LT_NS}-web, namespace: ${LT_NS}, labels: { app.kubernetes.io/part-of: ${LT_NS}, app.kubernetes.io/managed-by: anvil, anvil/tier: app } }
spec:
  selector: { app: ${LT_NS}-web }
  ports: [{ name: http, port: 80, targetPort: http }]
---
apiVersion: v1
kind: Service
metadata: { name: ${LT_NS}-worker, namespace: ${LT_NS}, labels: { app.kubernetes.io/part-of: ${LT_NS}, app.kubernetes.io/managed-by: anvil, anvil/tier: app } }
spec:
  selector: { app: ${LT_NS}-worker }
  ports: [{ name: http, port: 8081, targetPort: http }]
---
# Basic auth (the secret holds exactly one key, `users`) and noindex: nobody stumbles on it, no search engine lists it.
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata: { name: ${LT_NS}-auth, namespace: ${LT_NS} }
spec:
  basicAuth: { secret: ${LT_NS}-auth }
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata: { name: ${LT_NS}-noindex, namespace: ${LT_NS} }
spec:
  headers: { customResponseHeaders: { X-Robots-Tag: "noindex, nofollow" } }
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${LT_NS}
  namespace: ${LT_NS}
  labels: { app.kubernetes.io/part-of: ${LT_NS}, app.kubernetes.io/managed-by: anvil, anvil/tier: app }
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.middlewares: ${LT_NS}-${LT_NS}-auth@kubernetescrd,${LT_NS}-${LT_NS}-noindex@kubernetescrd
spec:
  ingressClassName: traefik
  tls: [{ hosts: ["${LT_HOST}"] }]
  rules:
    - host: "${LT_HOST}"
      http:
        paths:
          - { path: /, pathType: Prefix, backend: { service: { name: "${LT_NS}-web", port: { name: http } } } }
