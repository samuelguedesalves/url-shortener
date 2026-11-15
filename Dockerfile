FROM elixir:1.18.0-otp-27

ENV MIX_ENV=prod
WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

# Dependencies first, so source changes do not re-fetch them.
COPY mix.exs mix.lock ./
COPY config config
COPY apps/shortener_core/mix.exs apps/shortener_core/mix.exs
COPY apps/write_api/mix.exs apps/write_api/mix.exs
COPY apps/redirect_api/mix.exs apps/redirect_api/mix.exs
RUN mix deps.get --only prod && mix deps.compile

COPY apps apps

# Dashboard assets (Tailwind and esbuild binaries are downloaded here, so the build needs network).
# Run from apps/write_api: the asset aliases and the output in priv/static live there.
RUN cd apps/write_api && mix assets.setup && mix assets.deploy

RUN mix compile
