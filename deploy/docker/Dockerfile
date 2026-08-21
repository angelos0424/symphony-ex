FROM hexpm/elixir:1.19.5-erlang-26.2.5.5-debian-bullseye-20260421-slim AS build

WORKDIR /app
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*
RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

COPY lib lib/
COPY config config/
COPY bin bin/
COPY .formatter.exs ./
COPY README.md DEPLOY.md WORKFLOW.md ./
RUN mix compile
RUN mix release

FROM node:22-bullseye-slim AS runtime

ARG CODEX_NPM_VERSION=latest
ARG GH_VERSION=2.98.0
RUN apt-get update && apt-get install -y ca-certificates curl git openssh-client inotify-tools locales tzdata && rm -rf /var/lib/apt/lists/*
RUN arch="$(dpkg --print-architecture)" \
    && curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${arch}.tar.gz" -o /tmp/gh.tar.gz \
    && tar -xzf /tmp/gh.tar.gz -C /tmp \
    && install -m 0755 "/tmp/gh_${GH_VERSION}_linux_${arch}/bin/gh" /usr/local/bin/gh \
    && rm -rf /tmp/gh.tar.gz "/tmp/gh_${GH_VERSION}_linux_${arch}" \
    && gh --version
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
RUN npm install -g @openai/codex@${CODEX_NPM_VERSION}

WORKDIR /app
COPY --from=build /app/_build/prod/rel/symphony_ex ./
COPY deploy/docker/entrypoint.sh /usr/local/bin/symphony-entrypoint
RUN chmod +x /usr/local/bin/symphony-entrypoint

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV TZ=Asia/Seoul
ENV ELIXIR_ERL_OPTIONS=+fnu
ENTRYPOINT ["/usr/local/bin/symphony-entrypoint"]
