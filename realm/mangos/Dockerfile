# Open Vanilla world server image: the stock wenilla-realm-mangos image with mangosd rebuilt from the
# same CMaNGOS commit plus Open Vanilla's patches (realm/mangos/*.patch):
#   0001  src/game/OpenVanilla/: the WNL hook for the Classic+ addon suite (Compass pins, Vanguard
#         threat, Ledger prices, Visage debuff timers) and the Star Pouch at every level-up
#   0013  leveling pace (src/game/OpenVanilla/Pace.*): faster flights, flight paths by level, campfire
#         rest, Veteran Mentor quest XP, level-scaled exploration XP, starter items back on abandon,
#         and the capital training dummies; every OpenVanilla.Pace.* switch is off unless set
#   0016  Herald (the bot AI playing a player's character) doesn't pull into packs: in the PlayerBots
#         module (src/modules/PlayerBots), which the patch loop below reaches from the CMaNGOS root
#   0017  custom strategy names and lines from chat are safe in SQL (PlayerBots module too)
#   0018  falling through the world puts the player back where they last stood instead of killing them
#   0019  the hidden in-game GM console's feed (.wnl gm), no slurs or obscenities in names, and no random-bot
#         chatter (level ups, loot, small talk) in the World channel
#   0020  Herald's brain (PlayerBots playerbot/HeraldBrain.*): pull decisions by a fight predictor, stuck
#         recovery in seconds, grouping with other Heralds, gray-only vendor runs, fight and stuck logs,
#         notes for his panel; plus eleven upstream playerbots fixes and a FleeManager fix
#   0021  Duels (OpenVanilla.Duels = 1, its own realm, hetzner/duels_up.sh): 1v1 best of three, a practice
#         mode u1, every finished match logged for the website's ladder and feed
#   0022  a Star Pouch opened again with its loot all taken is spent, not an empty loot window
#   0023  OpenVanilla.Mounts: the racial mount and Riding 75 from level 1, the swift one and Riding 150 from
#         40, learned at login and level-up and put on the action bar
# Same flags as upstream's mangos.Dockerfile, so the binary drops into the upstream image.
# Built by .github/workflows/realm-image.yml (~30 min cold; a patch-only change recompiles just the
# files it touches, through ccache kept between runs); never on the game server.
ARG BASE=ghcr.io/arnesen/wenilla-realm-mangos:latest
FROM debian:bookworm AS build
ARG MANGOS_CLASSIC_COMMIT
ARG PLAYERBOTS_COMMIT
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential cmake git ca-certificates ccache \
      libboost-all-dev libmariadb-dev libmariadb-dev-compat libssl-dev zlib1g-dev libbz2-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /opt/src
# only the pinned commits, without history (GitHub serves a commit by its id)
RUN git init -q mangos-classic \
    && git -C mangos-classic fetch -q --depth 1 https://github.com/cmangos/mangos-classic "${MANGOS_CLASSIC_COMMIT}" \
    && git -C mangos-classic checkout -q FETCH_HEAD \
    && git -C mangos-classic submodule update --init --recursive --depth 1 \
    && rm -rf mangos-classic/src/modules/PlayerBots \
    && git init -q mangos-classic/src/modules/PlayerBots \
    && git -C mangos-classic/src/modules/PlayerBots fetch -q --depth 1 https://github.com/cmangos/playerbots "${PLAYERBOTS_COMMIT}" \
    && git -C mangos-classic/src/modules/PlayerBots checkout -q FETCH_HEAD
COPY *.patch /opt/patches/
RUN for p in /opt/patches/*.patch; do echo "applying $p"; git -C mangos-classic apply --whitespace=nowarn "$p"; done
# ccache: the workflow hands its cache in at /root/.ccache and keeps it after the build. The
# sloppiness settings are the ones ccache's manual asks for with GCC precompiled headers (PCH=ON).
ENV CCACHE_DIR=/root/.ccache CCACHE_MAXSIZE=3G CCACHE_COMPILERCHECK=content \
    CCACHE_SLOPPINESS=pch_defines,time_macros,include_file_mtime,include_file_ctime
RUN --mount=type=cache,target=/root/.ccache \
    ccache -z && cmake -S mangos-classic -B /opt/build \
      -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
      -DFETCHCONTENT_SOURCE_DIR_PLAYERBOTS=/opt/src/mangos-classic/src/modules/PlayerBots \
      -DCMAKE_INSTALL_PREFIX=/opt/mangos \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_GAME_SERVER=ON -DBUILD_LOGIN_SERVER=OFF \
      -DBUILD_EXTRACTORS=OFF -DBUILD_PLAYERBOTS=ON -DBUILD_AHBOT=ON -DPCH=ON \
    && cmake --build /opt/build -j"$(nproc)" \
    && cmake --install /opt/build \
    && ccache -s

FROM ${BASE}
LABEL dev.openvanilla.patches="wnl-hook,star-pouch,openvanilla-names,pace,bug-reports,world-channel,herald-pulls,custom-strategy-sql,fall-rescue,gm-feed-names,duels" \
      org.opencontainers.image.description="wenilla-realm-mangos + Open Vanilla WNL hook and Star Pouches"
COPY --from=build /opt/mangos/bin/mangosd /opt/mangos/bin/mangosd
# The bot AI (Herald, realm bots) reads ../etc/aiplayerbot.conf from mangosd's cwd: the -p flag in
# mangosd-start.sh sets the old playerbot's path, not the AI's, so without this link it logs "AI Playerbot
# is Disabled. Unable to open configuration file" whatever /config/aiplayerbot.conf says (as anticheat.conf).
RUN ln -sf /config/aiplayerbot.conf /opt/mangos/etc/aiplayerbot.conf
