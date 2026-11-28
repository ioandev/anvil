# syntax=docker/dockerfile:1
# anvil docs: Astro + Starlight static build, served by an unprivileged nginx on :8080.
#
#   podman build -t anvil-docs .                                         # base /anvil, site https://ioan.dev
#   podman build --build-arg ASTRO_BASE=/ --build-arg ANVIL_DOCS_SITE=https://docs.example.com -t anvil-docs .
#   podman run --rm -p 8080:8080 --read-only --tmpfs /tmp anvil-docs     # then http://localhost:8080/anvil
#
# The base path is baked in at build time (every link contains it), so one image serves one base path.

FROM docker.io/library/node:24-slim AS build
WORKDIR /src
ENV ASTRO_TELEMETRY_DISABLED=1
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY . .
ARG ASTRO_BASE=/anvil
ARG ANVIL_DOCS_SITE=https://ioan.dev
ENV ASTRO_BASE=${ASTRO_BASE} ANVIL_DOCS_SITE=${ANVIL_DOCS_SITE}
# Builds the site and fails on any broken internal link (scripts/check-links.mjs).
RUN npm run build
# Lay the files out under the base path and render the nginx config for it.
RUN set -eu; \
    B="$(printf '%s' "$ASTRO_BASE" | sed 's#^/*##; s#/*$##')"; [ -n "$B" ] && B="/$B"; \
    mkdir -p "/out/html$B"; cp -a dist/. "/out/html$B/"; \
    sed "s#__BASE__#$B#g" nginx.conf > /out/nginx.conf; \
    if [ -z "$B" ]; then sed -i '/# only-with-base/d' /out/nginx.conf; fi

# nginx-unprivileged: non-root (uid 101), listens on 8080, stable branch, alpine.
FROM docker.io/nginxinc/nginx-unprivileged:1.30-alpine
COPY --from=build /out/nginx.conf /etc/nginx/nginx.conf
COPY --from=build /out/html /usr/share/nginx/html
USER 101:101
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --retries=3 CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1
# Skip the image's entrypoint scripts (they edit files under /etc/nginx, which a read-only root can't allow).
ENTRYPOINT ["nginx", "-g", "daemon off;"]
