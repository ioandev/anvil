# Authenticated Origin Pulls: every TLS handshake must present a client cert
# signed by our CA. Only Cloudflare has it (uploaded per zone by
# scripts/cloudflare-zones.py), so not even other Cloudflare customers' zones
# pointed at this IP get through. A TLSOption named "default" applies to every
# router (all Ingresses) that doesn't pick another.
apiVersion: v1
kind: Secret
metadata:
  name: origin-pull-ca
  namespace: kube-system
type: Opaque
data:
  tls.ca: ${ca_crt_b64}
---
apiVersion: traefik.io/v1alpha1
kind: TLSOption
metadata:
  name: default
  namespace: kube-system
spec:
  minVersion: VersionTLS12
  clientAuth:
    secretNames: [origin-pull-ca]
    clientAuthType: RequireAndVerifyClientCert
