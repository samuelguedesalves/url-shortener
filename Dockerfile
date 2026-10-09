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
RUN mix compile
