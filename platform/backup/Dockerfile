# the server's backup image: dumps (MariaDB client, sqlite3), uploads and emails (curl) and the morning check (jq).
# Used by the nightly backup CronJobs (platform/atlas and any app's, labelled component=backup) and health-watch (platform/webhook). Build from this folder:
#   podman build -t ${ANVIL_REGISTRY}/anvil-backup:<tag> platform/backup
FROM docker.io/library/mariadb:13.0.2
RUN apt-get update \
 && apt-get install -y --no-install-recommends sqlite3 curl jq ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY server-backup.sh /usr/local/bin/server-backup
COPY health-watch.sh /usr/local/bin/health-watch
RUN chmod 755 /usr/local/bin/server-backup /usr/local/bin/health-watch
ENTRYPOINT ["/usr/local/bin/server-backup"]
