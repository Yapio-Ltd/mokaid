# --- Build stage ---
FROM hexpm/elixir:1.17.3-erlang-27.1.2-debian-bookworm-20241016-slim AS build

RUN apt-get update -y && apt-get install -y build-essential git \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY apps/api/mix.exs apps/api/mix.lock* ./
RUN mix deps.get --only prod && mix deps.compile

COPY apps/api/config ./config
COPY apps/api/lib ./lib
COPY apps/api/priv ./priv

RUN mix compile && mix release

# --- Runtime stage ---
FROM debian:bookworm-slim AS runtime

RUN apt-get update -y \
    && apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app
RUN useradd --create-home mokaid
USER mokaid

COPY --from=build --chown=mokaid:mokaid /app/_build/prod/rel/mokaid ./

ENV PHX_SERVER=true
EXPOSE 4000

CMD ["bin/mokaid", "start"]
