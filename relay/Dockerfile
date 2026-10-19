FROM rust:1-bookworm AS build
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --release --locked

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* && useradd -r -u 10001 relay
COPY --from=build /src/target/release/openvanilla-relay /usr/local/bin/openvanilla-relay
USER relay
ENV RELAY_BIND=0.0.0.0:8080
EXPOSE 8080
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/openvanilla-relay"]
