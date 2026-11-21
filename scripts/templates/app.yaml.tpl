# {ns}: {host}. Written by scripts/new-site init; edit freely (sites.yaml describes it, scripts/sites.py check verifies).
# UIDs {uid_block} (sites.yaml). Rules: CLAUDE.md "Rules for every app".
apiVersion: v1
kind: Namespace
metadata:
  name: {ns}
  labels: {{ app.kubernetes.io/part-of: {ns}, app.kubernetes.io/managed-by: anvil, anvil/tier: app }}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {ns}-web
  namespace: {ns}
  labels:
    app.kubernetes.io/name: {ns}-web
    app.kubernetes.io/part-of: {ns}
    app.kubernetes.io/component: web
    app.kubernetes.io/managed-by: anvil
    anvil/tier: app
spec:
  replicas: 1
  strategy: {{ type: RollingUpdate, rollingUpdate: {{ maxSurge: 1, maxUnavailable: 0 }} }}   # a deploy never leaves zero ready pods
  selector: {{ matchLabels: {{ app: {ns}-web }} }}
  template:
    metadata:
      labels: {{ app: {ns}-web, app.kubernetes.io/name: {ns}-web, app.kubernetes.io/part-of: {ns}, app.kubernetes.io/component: web }}
    spec:
      enableServiceLinks: false                      # rule 5
      securityContext: {{ runAsUser: {uid}, runAsGroup: {uid}, runAsNonRoot: true }}   # rule 3
      containers:
        - name: web
          image: {image}
          ports: [{{ name: http, containerPort: {port} }}]
          securityContext: {{ allowPrivilegeEscalation: false, capabilities: {{ drop: [ALL] }} }}
          resources: {{ requests: {{ cpu: 10m, memory: 32Mi }}, limits: {{ memory: 128Mi }} }}
          lifecycle:                                 # finish in-flight requests; the kubelet's own sleep (no shell needed)
            preStop: {{ sleep: {{ seconds: 5 }} }}
          # Readiness = the port answers: a page check with a short timeout takes a busy pod out of service and turns
          # "slow" into "503 for everyone" (CAPACITY.md). Liveness checks the real endpoint, slowly (rule 11).
          readinessProbe: {{ tcpSocket: {{ port: http }}, periodSeconds: 5 }}
          livenessProbe:                             # rule 11
            httpGet: {{ path: {health}, port: http }}
            initialDelaySeconds: 120
            periodSeconds: 30
            timeoutSeconds: 10
            failureThreshold: 5
---
apiVersion: v1
kind: Service
metadata: {{ name: {ns}-web, namespace: {ns}, labels: {{ app.kubernetes.io/part-of: {ns}, app.kubernetes.io/managed-by: anvil, anvil/tier: app }} }}    # rule 2: project-prefixed
spec:
  selector: {{ app: {ns}-web }}
  ports: [{{ name: http, port: 80, targetPort: http }}]
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {ns}
  namespace: {ns}
  annotations: {{ traefik.ingress.kubernetes.io/router.entrypoints: websecure }}
spec:
  ingressClassName: traefik                          # rule 9: websecure, tls.hosts, no certresolver
  tls: [{{ hosts: [{host}] }}]
  rules:
    - host: {host}
      http:
        paths: [{{ path: /, pathType: Prefix, backend: {{ service: {{ name: {ns}-web, port: {{ name: http }} }} }} }}]
