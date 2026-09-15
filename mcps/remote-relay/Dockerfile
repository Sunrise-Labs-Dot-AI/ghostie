FROM caddy:2.10.2-alpine AS proxy
FROM oven/bun:1.3.14-alpine AS dependencies
WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile --production

FROM oven/bun:1.3.14-alpine
RUN apk add --no-cache su-exec
WORKDIR /app
COPY --from=proxy /usr/bin/caddy /usr/bin/caddy
COPY --from=dependencies /app/node_modules ./node_modules
COPY package.json ./
COPY src ./src
COPY deploy ./deploy
ENV PORT=8080 GHOSTIE_RELAY_DB=/data/relay.sqlite
EXPOSE 8080
ENTRYPOINT ["sh", "/app/deploy/start.sh"]
