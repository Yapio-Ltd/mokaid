# Native custom avatars use the same GLB decoder and texture pipeline as the
# desktop catalog. Conversion runs in the generation worker, never a client.
FROM node:22-bookworm-slim AS avatar-cooker
WORKDIR /opt/avatar-cooker
COPY apps/desktop/tools/asset-cooker/package*.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY apps/desktop/tools/asset-cooker/cook-custom.mjs apps/desktop/tools/asset-cooker/source-policy.mjs ./

# --- Build stage ---
FROM hexpm/elixir:1.17.3-erlang-27.1.2-debian-bookworm-20241016-slim AS build

RUN apt-get update -y && apt-get install -y build-essential git \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV MIX_ENV=prod

RUN mix local.hex 2.5.1 --force && mix local.rebar --force

COPY apps/api/mix.exs apps/api/mix.lock* ./
# Release containers do not retain a BEAM package inventory that the OS image
# scanner can audit. Check the lock with Hex before compiling it into a release.
RUN mix deps.get --only prod && mix hex.audit && mix deps.compile

COPY apps/api/config ./config
COPY apps/api/lib ./lib
COPY apps/api/priv ./priv

RUN mix compile && mix release

# --- Runtime stage ---
FROM debian:bookworm-slim AS runtime

# Explicitly refresh PCRE2 inherited from the base; unrelated installs can keep
# the vulnerable base version. Refuse a mirror that lacks the fixed revision.
RUN apt-get update -y \
    && apt-get install -y --no-install-recommends \
        libstdc++6 libatomic1 openssl libncurses6 locales ca-certificates libpcre2-8-0 \
    && dpkg --compare-versions "$(dpkg-query -W -f='${Version}' libpcre2-8-0)" ge '10.42-1+deb12u1' \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app
RUN useradd --create-home mokaid
USER mokaid

COPY --from=build --chown=mokaid:mokaid /app/_build/prod/rel/mokaid ./
COPY --from=avatar-cooker /usr/local/bin/node /usr/local/bin/node
COPY --from=avatar-cooker --chown=mokaid:mokaid /opt/avatar-cooker /opt/avatar-cooker
RUN node --input-type=module -e "await import('/opt/avatar-cooker/cook-custom.mjs')"

ENV MESHY_NATIVE_COOKER=/opt/avatar-cooker/cook-custom.mjs MESHY_NODE_BIN=/usr/local/bin/node

ENV PHX_SERVER=true
EXPOSE 4000

CMD ["bin/mokaid", "start"]
