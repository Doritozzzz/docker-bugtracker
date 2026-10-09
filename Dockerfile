FROM node:24-alpine

WORKDIR /app

# Dependencies first: this layer is rebuilt only when the lockfile changes.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

COPY src ./src

# Unprivileged user that ships with the image. Code and dependencies stay
# owned by root, so the process cannot modify them.
USER node

# Documentation only: publishing the port is decided in Compose.
EXPOSE 3000

# Liveness only: /live does not depend on PostgreSQL or Redis.
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -q -O /dev/null "http://127.0.0.1:${PORT:-3000}/live" || exit 1

CMD ["node", "src/server.js"]
