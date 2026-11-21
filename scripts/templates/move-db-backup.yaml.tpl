# Nightly off-site backup of a database that lives off atlas (scripts/move-db, docs: Operations → Scale a site out): created at the
# cutover, deleted at the move back. Same image and bucket as atlas-backup, its own folder (BACKUP_SOURCE), and the
# label app.kubernetes.io/component=backup, by which the morning check and /backups find it.
apiVersion: batch/v1
kind: CronJob
metadata:
  name: ${NAME}-backup
  namespace: ${NS}
  labels: { app.kubernetes.io/name: ${NAME}-backup, app.kubernetes.io/part-of: ${PART_OF}, app.kubernetes.io/managed-by: anvil, anvil/tier: app, app.kubernetes.io/component: backup }
spec:
  schedule: "50 3 * * *"
  timeZone: Etc/UTC
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 1
      template:
        metadata: { labels: { app.kubernetes.io/name: ${NAME}-backup, app.kubernetes.io/part-of: ${PART_OF}, app.kubernetes.io/component: backup } }
        spec:
          enableServiceLinks: false
          restartPolicy: Never
          imagePullSecrets: [{ name: anvil-registry }]
          securityContext: { runAsUser: ${UID}, runAsGroup: ${UID} }
${PLACEMENT}
          containers:
            - name: backup
              image: ${IMAGE}
              args: ["mariadb"]
              envFrom: [{ secretRef: { name: ${NAME}-backup } }]
              resources: { requests: { cpu: 50m, memory: 64Mi }, limits: { memory: 512Mi } }
              securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: [ALL] } }
              volumeMounts: [{ name: work, mountPath: /work }]
          volumes: [{ name: work, emptyDir: {} }]
