# syntax=docker/dockerfile:1
# Multi-stage build for the hosted taskweft MCP server.
# Stage 1 compiles the C++ NIF + an Elixir prod release (which excludes
# test-only deps like timex/tzdata/hackney/cowlib). Stage 2 is a slim runtime.

ARG ELIXIR_IMAGE=docker.io/hexpm/elixir:1.17.3-erlang-27.2-debian-bookworm-20241202-slim
ARG RUNTIME_IMAGE=docker.io/debian:bookworm-slim

# ---------- build ----------
FROM ${ELIXIR_IMAGE} AS build

# build-essential/g++ for the taskweft_nif C++20 NIF; git for github: deps; curl for rebar3.
RUN apt-get update -y \
  && apt-get install -y --no-install-recommends build-essential git ca-certificates make curl \
  && rm -rf /var/lib/apt/lists/*

ENV MIX_ENV=prod
WORKDIR /app

# Install hex + rebar3 WITHOUT hitting builds.hex.pm — OTP 27 rejects its cert
# chain with a key_usage_mismatch TLS alert (repo.hex.pm and GitHub are fine).
# hex comes from its git repo; rebar3 from its GitHub release.
RUN mix archive.install github hexpm/hex branch latest --force
RUN curl -fsSL -o /usr/local/bin/rebar3 https://github.com/erlang/rebar3/releases/latest/download/rebar3 \
  && chmod +x /usr/local/bin/rebar3 \
  && mix local.rebar rebar3 /usr/local/bin/rebar3 --force

COPY mix.exs mix.lock* ./
RUN mix deps.get --only prod
RUN mix deps.compile

COPY config config
COPY lib lib
RUN mix compile
RUN mix release

# ---------- runtime ----------
FROM ${RUNTIME_IMAGE} AS app

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 ca-certificates \
  && rm -rf /var/lib/apt/lists/*

ENV MIX_ENV=prod \
    PORT=8080 \
    LANG=C.UTF-8

WORKDIR /app
COPY --from=build /app/_build/prod/rel/taskweft_deploy ./

# Non-root
RUN useradd --create-home app && chown -R app:app /app
USER app

EXPOSE 8080
CMD ["/app/bin/taskweft_deploy", "start"]
