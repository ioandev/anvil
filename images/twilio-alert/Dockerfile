# Build context: the repo root.
#   podman build -t "$ANVIL_REGISTRY/twilio-alert:<tag>" .                     # amd64 (the server)
#   podman build --platform linux/arm64 -t localhost/twilio-alert:<tag> .                         # arm64 (the Mac mini)

FROM docker.io/library/node:24.21.0-alpine3.24 AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY tsconfig.json ./
COPY src ./src
RUN npm run build && npm prune --omit=dev

FROM docker.io/library/node:24.21.0-alpine3.24
WORKDIR /app
ENV NODE_ENV=production PORT=3000
# uid/gid 5490: the alerting block in sites.yaml.
RUN addgroup -S -g 5490 twilio && adduser -S -u 5490 -G twilio twilio
COPY --from=build --chown=twilio:twilio /app/package.json ./
COPY --from=build --chown=twilio:twilio /app/node_modules ./node_modules
COPY --from=build --chown=twilio:twilio /app/dist ./dist
USER 5490:5490
EXPOSE 3000
# node directly (not npm start), so it gets SIGTERM and shuts down cleanly.
CMD ["node", "dist/server.js"]
