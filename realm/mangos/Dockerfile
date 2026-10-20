# Open Vanilla world server image: the stock wenilla-realm-mangos image with mangosd rebuilt from the
# same CMaNGOS commit plus Open Vanilla's patches (realm/mangos/*.patch):
#   0001  src/game/OpenVanilla/: the WNL hook for the Classic+ addon suite (Compass pins, Vanguard
#         threat, Ledger prices, Visage debuff timers) and the Star Pouch at every level-up
#   0013  leveling pace (src/game/OpenVanilla/Pace.*): faster flights, flight paths by level, campfire
#         rest, Veteran Mentor quest XP, level-scaled exploration XP, starter items back on abandon,
#         and the capital training dummies; every OpenVanilla.Pace.* switch is off unless set
# Same flags as upstream's mangos.Dockerfile, so the binary drops into the upstream image.
# Built by .github/workflows/realm-image.yml (~30 min); never on the game server.
ARG BASE=ghcr.io/arnesen/wenilla-realm-mangos:latest
FROM debian:bookworm AS build
ARG MANGOS_CLASSIC_COMMIT
ARG PLAYERBOTS_COMMIT
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential cmake git ca-certificates \
      libboost-all-dev libmariadb-dev libmariadb-dev-compat libssl-dev zlib1g-dev libbz2-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /opt/src
RUN git clone --recursive https://github.com/cmangos/mangos-classic mangos-classic \
    && git -C mangos-classic checkout --recurse-submodules "${MANGOS_CLASSIC_COMMIT}" \
    && git -C mangos-classic submodule update --init --recursive \
    && rm -rf mangos-classic/src/modules/PlayerBots \
    && git clone https://github.com/cmangos/playerbots mangos-classic/src/modules/PlayerBots \
    && git -C mangos-classic/src/modules/PlayerBots checkout "${PLAYERBOTS_COMMIT}"
COPY *.patch /opt/patches/
RUN for p in /opt/patches/*.patch; do echo "applying $p"; git -C mangos-classic apply --whitespace=nowarn "$p"; done
RUN cmake -S mangos-classic -B /opt/build \
      -DFETCHCONTENT_SOURCE_DIR_PLAYERBOTS=/opt/src/mangos-classic/src/modules/PlayerBots \
      -DCMAKE_INSTALL_PREFIX=/opt/mangos \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_GAME_SERVER=ON -DBUILD_LOGIN_SERVER=OFF \
      -DBUILD_EXTRACTORS=OFF -DBUILD_PLAYERBOTS=ON -DBUILD_AHBOT=ON -DPCH=ON \
    && cmake --build /opt/build -j"$(nproc)" \
    && cmake --install /opt/build

FROM ${BASE}
LABEL dev.openvanilla.patches="wnl-hook,star-pouch,openvanilla-names,pace,bug-reports" \
      org.opencontainers.image.description="wenilla-realm-mangos + Open Vanilla WNL hook and Star Pouches"
COPY --from=build /opt/mangos/bin/mangosd /opt/mangos/bin/mangosd
