FROM oven/bun:1.3.14-alpine
WORKDIR /probe
ENV PROBE_BIND_HOST=0.0.0.0
ENV PORT=9443
COPY probe.ts ./probe.ts
USER bun
EXPOSE 9443
CMD ["bun", "run", "probe.ts"]
