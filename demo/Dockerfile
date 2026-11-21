# anvil-demo: one image, two processes (web: dist/server.js, worker: dist/worker.js).
# Build:  podman build --platform linux/amd64 -t anvil-demo:dev .
# Node.js 24 is the LTS line on 2026-10-27 (Node 26 becomes LTS on 2026-10-28: bump both FROM lines then).

# ---- build: compile TypeScript ----
FROM docker.io/library/node:24-alpine AS build
WORKDIR /src
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

# ---- deps: production dependencies only (all pure JavaScript, so they run on the glibc runtime below) ----
FROM docker.io/library/node:24-alpine AS deps
WORKDIR /src
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund && npm cache clean --force

# ---- runtime: distroless (no shell, no package manager), numeric non-root user ----
FROM gcr.io/distroless/nodejs24-debian13
WORKDIR /app
ENV NODE_ENV=production
COPY --from=deps /src/node_modules ./node_modules
COPY --from=build /src/dist ./dist
COPY package.json ./
USER 10001:10001
EXPOSE 8080 9090 8081
# The base image's ENTRYPOINT is node; the worker runs with args ["dist/worker.js"].
CMD ["dist/server.js"]
