FROM node:24-alpine AS frontend
WORKDIR /frontend
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci
COPY frontend/index.html frontend/svelte.config.js frontend/tsconfig.json frontend/vite.config.ts ./
COPY frontend/src src
RUN npm run check && npm run build

FROM ghcr.io/gleam-lang/gleam:v1.18.1-erlang-alpine AS build
WORKDIR /app
COPY gleam.toml manifest.toml ./
COPY src src
RUN gleam deps download && gleam export erlang-shipment

FROM erlang:28-alpine
RUN apk add --no-cache ca-certificates
WORKDIR /app
COPY --from=build /app/build/erlang-shipment ./
COPY --from=frontend /frontend/dist /app/public
ENV PORT=4000
EXPOSE 4000
CMD ["/bin/sh", "./entrypoint.sh", "run"]
