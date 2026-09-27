# Native custom avatars use the same GLB decoder and texture pipeline as the
# desktop catalog. Conversion runs in the generation worker, never a client.
FROM node:22-bookworm-slim AS avatar-cooker
WORKDIR /opt/avatar-cooker
COPY apps/desktop/tools/asset-cooker/package*.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY apps/desktop/tools/asset-cooker/cook-custom.mjs apps/desktop/tools/asset-cooker/source-policy.mjs apps/desktop/tools/asset-cooker/surface-kinds.mjs apps/desktop/tools/asset-cooker/character-normals.mjs ./
RUN node --input-type=module -e "await import('/opt/avatar-cooker/cook-custom.mjs')"

# Blender publishes Linux x64 builds, not Linux ARM64. The API remains ARM64;
# the isolated avatar worker uses the amd64 variant of this same release image.
FROM debian:bookworm-slim AS avatar-blender
ARG TARGETARCH
# Verified against the official Blender 5.2.0 checksum manifest:
# https://download.blender.org/release/Blender5.2/blender-5.2.0.sha256
RUN mkdir -p /opt/blender \
    && case "$TARGETARCH" in \
       amd64) apt-get update -y \
         && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
         && curl --fail --show-error --location --retry 3 \
           https://download.blender.org/release/Blender5.2/blender-5.2.0-linux-x64.tar.xz \
           --output /tmp/blender.tar.xz \
         && echo '96f6c181a30f4950607839dc84d42a354b250d8a0231b098b59b7bc69c351c48  /tmp/blender.tar.xz' | sha256sum --check --strict \
         && tar -xJf /tmp/blender.tar.xz --strip-components=1 -C /opt/blender \
         && rm /tmp/blender.tar.xz \
         && if ! /opt/blender/5.2/python/bin/python3.13 -m ensurepip --upgrade; then \
              curl --fail --show-error --location --retry 3 \
                https://bootstrap.pypa.io/get-pip.py --output /tmp/get-pip.py \
              && /opt/blender/5.2/python/bin/python3.13 /tmp/get-pip.py \
              && rm /tmp/get-pip.py; \
            fi \
         && /opt/blender/5.2/python/bin/python3.13 -m pip install --no-cache-dir --upgrade \
              'urllib3==2.8.0' 'setuptools==84.0.0' \
         && /opt/blender/5.2/python/bin/python3.13 -c 'import importlib.metadata as m; from pathlib import Path; assert tuple(int(p) for p in m.version("urllib3").split(".")[:3]) >= (2, 8, 0); vendor = Path("/opt/blender/5.2/python/lib/python3.13/site-packages/setuptools/_vendor"); wheel = next(vendor.glob("wheel-*.dist-info")).name.removeprefix("wheel-").removesuffix(".dist-info"); jaraco = next(vendor.glob("jaraco_context-*.dist-info")).name.removeprefix("jaraco_context-").removesuffix(".dist-info"); assert tuple(int(p) for p in wheel.split(".")[:3]) >= (0, 46, 2); assert tuple(int(p) for p in jaraco.split(".")[:3]) >= (6, 1, 0)' ;; \
       arm64) touch /opt/blender/API_ONLY_NO_BLENDER ;; \
       *) echo "Unsupported runtime architecture: $TARGETARCH" >&2; exit 1 ;; \
       esac

# This independently buildable stage verifies every runpy dependency inside the
# exact Linux renderer, without needing database credentials or paid API calls.
FROM debian:bookworm-slim AS avatar-preparer
RUN apt-get update -y && apt-get install -y --no-install-recommends \
      python3 libx11-6 libxi6 libxrender1 libxfixes3 libxxf86vm1 libxkbcommon0 libgl1 libegl1 libsm6 libice6 libgomp1 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
COPY --from=avatar-blender /opt/blender /opt/blender
COPY scripts/prepare-custom-avatar.py scripts/blender-avatar-quality.py scripts/blender-avatar-life.py scripts/validate-avatar-life.py scripts/avatar-process-runner.py /opt/avatar-preparer/
RUN python3 -m py_compile /opt/avatar-preparer/*.py \
    && if [ -x /opt/blender/blender ]; then \
      /opt/blender/blender --background --factory-startup --python-exit-code 1 \
        --python-expr 'import bpy, runpy; assert bpy.app.version == (5, 2, 0); [runpy.run_path("/opt/avatar-preparer/" + name, run_name="image_smoke") for name in ("blender-avatar-quality.py", "blender-avatar-life.py", "validate-avatar-life.py", "prepare-custom-avatar.py")]'; \
    fi

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
        libstdc++6 libatomic1 openssl libncurses6 locales ca-certificates libpcre2-8-0 python3 \
        libx11-6 libxi6 libxrender1 libxfixes3 libxxf86vm1 libxkbcommon0 libgl1 libegl1 libsm6 libice6 libgomp1 \
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
COPY --from=avatar-preparer /opt/blender /opt/blender
COPY --from=avatar-preparer --chown=mokaid:mokaid /opt/avatar-preparer /opt/avatar-preparer
RUN node --input-type=module -e "await import('/opt/avatar-cooker/cook-custom.mjs')"
RUN python3 -m py_compile /opt/avatar-preparer/*.py \
    && if [ -x /opt/blender/blender ]; then \
      /opt/blender/blender --background --factory-startup --python-exit-code 1 \
        --python-expr 'import bpy; assert bpy.app.version == (5, 2, 0)'; \
    fi

ENV MESHY_NATIVE_COOKER=/opt/avatar-cooker/cook-custom.mjs MESHY_NODE_BIN=/usr/local/bin/node
ENV MOKAID_AVATAR_BLENDER=/opt/blender/blender \
    MOKAID_AVATAR_PREPARER=/opt/avatar-preparer/prepare-custom-avatar.py \
    MOKAID_AVATAR_PYTHON=/usr/bin/python3 \
    MOKAID_AVATAR_PROCESS_RUNNER=/opt/avatar-preparer/avatar-process-runner.py

ENV PHX_SERVER=true
EXPOSE 4000

CMD ["bin/mokaid", "start"]
