FROM rust:1-alpine AS build
RUN apk add --no-cache musl-dev
WORKDIR /src
COPY server/ server/
COPY core/tterm-vault/ core/tterm-vault/
RUN cargo build --release --manifest-path server/Cargo.toml

FROM alpine:3
COPY --from=build /src/server/target/release/tterm-server /usr/local/bin/tterm-server
VOLUME /data
EXPOSE 8722
ENTRYPOINT ["tterm-server", "--listen", "0.0.0.0:8722", "--data", "/data"]
