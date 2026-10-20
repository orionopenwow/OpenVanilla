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
#   0028  no falling through the world on load (client): when the stream stalls before the tile under the
#         body has ground, the settle hold keeps the body still (up to 45 s) instead of turning gravity on
# The workflow (.github/workflows/realm-image.yml) compiles the browser client and the realm
# service on the runner, where their build cache survives between runs, and stages them in out/:
#   out/wenilla-realm   cargo build --release -p wenilla-realm
#   out/www/            scripts/web-build.sh's web/dist (without its index.html)
# This file only lays them onto the upstream image. Never built on the game server.
ARG BASE=ghcr.io/arnesen/wenilla-realm:latest
FROM ${BASE}
LABEL org.opencontainers.image.source="https://github.com/orionopenwow/OpenVanilla" \
      org.opencontainers.image.description="wenilla-realm + Open Vanilla Discord sign-in and addon engine fixes"
COPY out/wenilla-realm /app/wenilla-realm
COPY out/www/ /app/www/
# Open Vanilla login backdrop: the page module, a 1.3 MB looping video (VP9 fallback) and its poster (see 0004).
COPY login-backdrop/ /app/www/
