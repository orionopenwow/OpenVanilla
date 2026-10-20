# Open Vanilla realm image: the stock wenilla-realm image with the service AND the browser client
# rebuilt from the same commit plus Open Vanilla's patches (realm/patches/*.patch):
#   0001  Discord sign-in (service)
#   0002  addon engine fixes G1–G5 (client): realm-patch addons, saved settings on the web,
#         UnitCanAssist / UnitIsTrivial, the chat edit box's input-language script
#   0003  launcher sign-in (service): /auth/launcher loopback flow, one-time codes, launcher tokens
#   0004  login backdrop (client + play page): no 3D gate and a transparent canvas on the login
#         screen, so login-backdrop/ (a looping video, copied in below) shows behind the form
#   0005  character create (client): a nine-slot class grid (five across, 36 px), so Classic+ races
#         with eight or nine classes no longer run into the dials below it
#   0016  sign-in (service): the Open Vanilla sign-in page (art in assets/brand, served at /brand/),
#         Discord straight from the button, no Discord trip when already signed in, back to the
#         page that asked, "Continue as …", 60-day sliding sessions that rotate only on page loads
#   0017  guest accounts (service): "Play free as a guest" (a key cookie on the device), resume on
#         that device, link Discord later to keep the characters; per-IP and daily limits,
#         idle guests removed after 30 days. OPENVANILLA_GUESTS=0 turns it off.
#   0019  dressing room (client): an addon's named DressUpModel (the Transmog window) draws the
#         3D character, turns and empties with it; anonymous model panes can't undress it. Sets
#         OPENVANILLA_ONE_DRESSING_ROOM so addons know one dressing room draws at a time.
#   0020  faster loads (client page + build) and the Open Vanilla name (service pages): the wasm is
#         compiled from the fetched Response so browsers can cache the compiled code, 24 boot
#         downloads at once, brotli -q 11, a build without wasm-opt fails (WEB_REQUIRE_OPT, below)
# Built by .github/workflows/realm-image.yml (~40 min; longer with the ship profile); never on the game server.
ARG BASE=ghcr.io/arnesen/wenilla-realm:latest
FROM rust:1-bookworm AS build
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      clang lld cmake pkg-config brotli curl git ca-certificates \
      libssl-dev libasound2-dev libudev-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY wenilla/ .
# The browser client, exactly as upstream's realm.Dockerfile builds it (web-setup pins the
# wasm-bindgen version to Cargo.lock), from the patched tree.
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    bash scripts/web-setup.sh
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/src/target \
    # Open Vanilla: the "ship" profile (fat LTO, one codegen unit: measured -5% CPU in the world),
    # and fail rather than ship a module without wasm-opt's -O3 pass (measured +6% frame rate).
    # Fat LTO can outgrow the build machine's memory; then the image is built with the release
    # profile instead (still wasm-opt -O3) rather than not at all. CARGO_BUILD_JOBS keeps the
    # compile's own memory down so the link has room.
    (CARGO_BUILD_JOBS=2 WEB_GPU=1 WEB_PROFILE=ship WEB_REQUIRE_OPT=1 bash scripts/web-build.sh \
      || { echo "ship build failed (memory?): building with the release profile instead"; \
           WEB_GPU=1 WEB_PROFILE=release WEB_REQUIRE_OPT=1 bash scripts/web-build.sh; }) \
    && cp -r web/dist /opt/www && rm -f /opt/www/index.html
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/src/target \
    cargo build --release --locked -p wenilla-realm && cp target/release/wenilla-realm /wenilla-realm

FROM ${BASE}
LABEL org.opencontainers.image.source="https://github.com/orionopenwow/OpenVanilla" \
      org.opencontainers.image.description="wenilla-realm + Open Vanilla Discord sign-in and addon engine fixes"
COPY --from=build /wenilla-realm /app/wenilla-realm
COPY --from=build /opt/www /app/www
# Open Vanilla login backdrop: the page module, a 1.3 MB looping video (VP9 fallback) and its poster (see 0004).
COPY login-backdrop/ /app/www/
