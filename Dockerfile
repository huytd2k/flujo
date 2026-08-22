FROM ghcr.io/gleam-lang/gleam:v1.18.1-erlang-alpine AS build
WORKDIR /app
COPY gleam.toml manifest.toml ./
COPY src src
RUN gleam deps download && gleam export erlang-shipment

FROM erlang:28-alpine
RUN apk add --no-cache ca-certificates
WORKDIR /app
COPY --from=build /app/build/erlang-shipment ./
ENV PORT=4000
EXPOSE 4000
CMD ["/bin/sh", "./entrypoint.sh", "run"]
