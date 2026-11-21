# webhookd (github.com/ncarlier/webhookd) at a pinned release, plus one patch (logger.patch):
#   - the request log redacts secret query parameters (code, token, password -> ok / wrong / set), so the status code
#     and tokens never reach a log viewer while guessing attempts still show;
#   - the client IP comes from CF-Connecting-IP (set by Cloudflare; the left-most X-Forwarded-For is client-forgeable).
# The binary replaces the one in upstream's own "distrib" image (bash, curl, jq, git: what platform/webhook/hooks need).
#   podman build -t "$ANVIL_REGISTRY/webhookd:<tag>" images/webhookd
ARG WEBHOOKD_VERSION=v1.22.1
FROM docker.io/library/golang:1.24 AS build
ARG WEBHOOKD_VERSION
RUN git clone --depth 1 --branch "$WEBHOOKD_VERSION" https://github.com/ncarlier/webhookd /src
WORKDIR /src
COPY logger.patch /tmp/logger.patch
RUN git apply /tmp/logger.patch && go test ./pkg/middleware/ \
 && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X github.com/ncarlier/webhookd/pkg/version.Version=${WEBHOOKD_VERSION}-redact" -o /webhookd .

FROM docker.io/ncarlier/webhookd:1.22.1-distrib
COPY --from=build /webhookd /usr/local/bin/webhookd
