# Customizes the Traefik Helm chart bundled with k3s (kube-system/traefik).
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    # Pin Traefik to the master; with Cloudflare proxying + agents closed to
    # the public internet, only the master serves 80/443.
    nodeSelector:
      node-role.kubernetes.io/control-plane: "true"
%{ if cloudflare_enabled ~}
    # Behind Cloudflare: no ACME and no Cloudflare API token on the server.
    # Origins serve Cloudflare Origin CA certs from the default TLS store
    # (platform/origin-ca, scripts/origin-certs.py); only Cloudflare connects
    # (Authenticated Origin Pulls), and it trusts them in Full (strict).
%{ else ~}
    # Without Cloudflare: browsers connect directly, so use Let's Encrypt via
    # TLS-ALPN. acme.json must survive pod restarts or certs get re-issued.
    persistence:
      enabled: true
      size: 128Mi
      path: /data
    certificatesResolvers:
      letsencrypt:
        acme:
          email: ${acme_email}
          storage: /data/acme.json
          tlsChallenge: true
%{ if acme_ca_server != "" ~}
          caServer: ${acme_ca_server}
%{ endif ~}
    # ACME storage must be chmod 600 or Traefik refuses to start (chart issue #396).
    deployment:
      initContainers:
        - name: volume-permissions
          image: busybox:1.37
          command: ["sh", "-c", "touch /data/acme.json && chmod 600 /data/acme.json"]
          volumeMounts:
            - name: data
              mountPath: /data
%{ endif ~}
    ports:
      web:
        redirections:
          entryPoint:
            to: websecure
            scheme: https
            permanent: true
%{ if cloudflare_enabled ~}
      # Keep Cloudflare's X-Forwarded-For chain so apps (rate limits, audit logs)
      # see the visitor. Traffic reaches Traefik
      # via k3s ServiceLB, which SNATs it to a pod-network address (10.42.x)
      # despite externalTrafficPolicy: Local, so the pod CIDR must be trusted
      # too, or Traefik replaces the chain with that internal IP and every
      # visitor shares one bucket. Safe: Authenticated Origin Pulls means only
      # Cloudflare can complete a handshake. Apps then see
      # "<visitor>, 10.42.x.x" and trust 2 hops (TRUST_PROXY=2).
      websecure:
        forwardedHeaders:
          trustedIPs:
            - "10.42.0.0/16"
%{ for r in cloudflare_ranges ~}
            - "${r}"
%{ endfor ~}
%{ endif ~}
    # Keep the real TCP peer through ServiceLB (otherwise SNAT'd to a node IP).
    service:
      spec:
        externalTrafficPolicy: Local
