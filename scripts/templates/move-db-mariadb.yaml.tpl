# A project's own MariaDB, used when its database moves off atlas (scripts/move-db, docs: Operations → Scale a site out).
# Rendered by scripts/move-db (never deployed by node.sh deploy): ${NAME} in namespace ${NS}, on pool ${POOL}
# (empty: no pool, for the throwaway tests on the server). It starts read-only as a copy of the project's database on
# atlas, follows atlas live, and becomes the primary at the cutover; it then writes its own binary log (only ${DB},
# GTID domain ${DOMAIN_ID}) so atlas can follow it back.
apiVersion: v1
kind: Service
metadata:
  name: ${NAME}
  namespace: ${NS}
  labels: { app.kubernetes.io/part-of: ${PART_OF}, app.kubernetes.io/managed-by: anvil, anvil/tier: app }
spec:
  selector: { app: ${NAME} }
  ports: [{ name: mysql, port: 3306, targetPort: mysql }]
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: ${NAME}
  namespace: ${NS}
  labels: { app.kubernetes.io/name: ${NAME}, app.kubernetes.io/part-of: ${PART_OF}, app.kubernetes.io/managed-by: anvil, anvil/tier: app, app.kubernetes.io/component: database }
spec:
  serviceName: ${NAME}
  replicas: 1
  selector: { matchLabels: { app: ${NAME} } }
  template:
    metadata: { labels: { app: ${NAME}, app.kubernetes.io/name: ${NAME}, app.kubernetes.io/part-of: ${PART_OF}, app.kubernetes.io/component: database } }
    spec:
      enableServiceLinks: false
      terminationGracePeriodSeconds: 60
      securityContext: { runAsUser: ${UID}, runAsGroup: ${UID}, fsGroup: ${UID} }
${PLACEMENT}
      containers:
        - name: mariadb
          image: ${IMAGE}
          args:
            - --character-set-server=utf8mb4
            - --collation-server=utf8mb4_unicode_ci
            - --innodb-buffer-pool-size=${BUFFER_POOL}
            - --max-connections=300
            - --max-allowed-packet=64M
            - --innodb-ft-min-token-size=2
            - --innodb-ft-enable-stopword=0
            - --performance-schema=OFF
            - --server-id=${SERVER_ID}
            - --gtid-domain-id=${DOMAIN_ID}
            - --log-bin=${NAME}-bin
            - --log-basename=${NAME}
            - --binlog-format=ROW
            - --gtid-strict-mode=ON
            - --binlog-expire-logs-seconds=172800
            - --binlog-do-db=${DB}
            - --replicate-do-db=${DB}
            # Until the cutover it is a copy: only replication (and root) may write.
            - --read-only=ON
          env:
            - { name: MARIADB_ROOT_PASSWORD, valueFrom: { secretKeyRef: { name: ${NAME}-secrets, key: MARIADB_ROOT_PASSWORD } } }
            - { name: MARIADB_ROOT_HOST, value: localhost }
            - { name: REPL_PASSWORD, valueFrom: { secretKeyRef: { name: ${NAME}-secrets, key: REPL_PASSWORD } } }
            - { name: SOURCE_HOST, value: "${SOURCE_HOST}" }
            - { name: REPL_USER, value: "${REPL_USER}" }
          ports: [{ name: mysql, containerPort: 3306 }]
          resources: { requests: { cpu: 100m, memory: ${MEMORY_REQUEST} }, limits: { memory: ${MEMORY_LIMIT} } }
          readinessProbe: { exec: { command: ["healthcheck.sh", "--connect", "--innodb_initialized"] }, periodSeconds: 2 }
          livenessProbe: { exec: { command: ["healthcheck.sh", "--connect", "--innodb_initialized"] }, initialDelaySeconds: 120, periodSeconds: 30, timeoutSeconds: 10, failureThreshold: 5 }
          volumeMounts:
            - { name: data, mountPath: /var/lib/mysql }
            - { name: work, mountPath: /work }
      volumes:
        - { name: work, emptyDir: {} }
  volumeClaimTemplates:
    - metadata: { name: data }
      spec:
        accessModes: [ReadWriteOnce]
        storageClassName: local-path
        resources: { requests: { storage: ${STORAGE} } }
