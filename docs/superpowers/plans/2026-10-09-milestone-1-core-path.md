# Milestone 1: Core Path Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A working write path and redirect path: `POST /urls` creates a short link in Cassandra, `GET /{code}` redirects through a Redis cache-aside, all runnable with `docker compose up`.

**Architecture:** An Elixir umbrella with three apps. `shortener_core` holds the shared clients and behaviours (`KeySource`, `UrlStore`, `Cache`, Base62) and no service logic. `write_api` and `redirect_api` are hand-written Phoenix endpoints (Phoenix as a library: endpoint, router, controller, no generators) that depend only on `shortener_core`. Each behaviour has an in-memory fake for unit tests and a real implementation (Cassandra via Xandra, Redis via Redix) checked by the same contract tests.

**Tech Stack:** Erlang 27.0, Elixir 1.18.0, Phoenix 1.8, Bandit, Jason, Xandra 0.20, Redix 1.9, Cassandra 5, Redis 7, Docker Compose v2.

**Spec:** `docs/superpowers/specs/2026-10-07-url-shortener-design.md` (milestone 1 of §13). Decisions: `docs/adr/0001` to `docs/adr/0006`. Read both before starting.

**Scope:** milestone 1 only. Not in this plan, each is a later milestone with its own plan: KGS and Key DB (M2), rate limiting and the `edge` app (M3), Kafka click events, `click_consumer` and `analytics_api` (M4), dashboard and URL safety check (M5), second load balancer, k6 load test, Prometheus metrics, architecture README (M6). The milestone-1 `KeySource` is the in-process generator. `redirect_api` does not publish click events yet.

**How this plan was checked:** every file below was built and run in a scratch umbrella before the plan was written: 88 unit tests, 14 integration tests against real Cassandra 5 and Redis 7, `scripts/smoke.sh` against the Compose stack, and manual Redis-down and Cassandra-down drills. If a command's output differs from what is shown, stop and find out why before going on.

## Global Constraints

- Elixir umbrella, one OTP app per service. `shortener_core` is the only shared app and holds no service logic. Services never call another service's modules (spec §2).
- Toolchain pinned in `.tool-versions`: `erlang 27.0`, `elixir 1.18.0-otp-27`.
- Codes are 7-character base62 (spec §3). Custom aliases are 3 to 32 characters from `[0-9A-Za-z_-]`.
- Cassandra consistency is QUORUM for every statement, set once in `ShortenerCore.Cassandra` as `default_consistency`. No call site overrides it. Conditional statements add `serial_consistency: :serial` (ADR 0003).
- `urls` is written in two steps: `INSERT ... IF NOT EXISTS` with **no TTL** to claim the code, then `UPDATE ... USING TTL` on `long_url` only. Never `INSERT ... USING TTL` on `urls`. A code is never reused after its link expires (ADR 0004).
- Default and maximum link lifetime is 10 years: `315_360_000` seconds (spec §4, ADR 0004).
- Redirects are `302` with `Cache-Control: no-store`. The same header goes on the 404, 410 and 503 responses (ADR 0006).
- When Cassandra is unavailable, a cache miss returns 503, never 404, and nothing is cached (ADR 0003). Cache hits still redirect (spec §10).
- When Redis is unavailable, reads go straight to Cassandra and writes still succeed (spec §10).
- A generated key that clashes with an existing code is discarded and the next key is taken. After 3 clashes in a row the request returns 503 (ADR 0001).
- A cache entry for a destination never outlives the link's remaining TTL (spec §5, ADR 0004).
- Local runs use replication factor 1; production uses 3 (spec §1, ADR 0003).
- Unit tests must pass without Docker. Tests that need Cassandra or Redis are tagged `:integration` and excluded unless `INTEGRATION=1` (spec §12).
- Code comments cite decisions as `ADR 000N`.

## Review Focus

Inputs and failure modes the spec implies but a straightforward implementation would miss. Each has a test in the task shown.

1. **A long URL containing CR, LF, a space or another control character.** It would be written straight into the `Location` header. Expect 422 `invalid_url` at write time. (Task 7, `a url with a newline`, `a url with a space`)
2. **A custom alias that shadows a route or has odd characters.** `health`, `urls` and `stats` are owned by the services. Aliases with `/`, spaces, or the wrong length must be rejected. (Task 7, alias cases)
3. **Redis down.** Creating links and following them must keep working. (Task 6 `unreachable` test, Task 7 `still succeeds when the cache is down`, Task 8 `serves from the store when Redis is down`)
4. **A crash between the two write steps.** The code stays claimed with no destination: it returns 410 and can never be claimed again. (Task 4 and 5 contract test, Task 7 `burns the code`, Task 8 `crash between the write steps`)
5. **Malformed or mistyped request bodies.** Invalid JSON gives 400 and a non-JSON content type gives 415, both with JSON bodies. A JSON array, a non-string `url`, and a non-integer or out-of-range `ttl_seconds` give 422. (Task 7, validation cases)
6. **Unusual paths on the redirect side.** `HEAD` must behave like `GET`. Codes that are too long or contain other characters return 404 without touching Cassandra or Redis. (Task 8, `HEAD` and `without touching the stores` cases)

---

## File Structure

```
.tool-versions  mix.exs  .formatter.exs  .gitignore  mix.lock  README.md
Dockerfile  .dockerignore  docker-compose.yml  scripts/smoke.sh
config/{config,dev,test,prod,runtime}.exs
apps/shortener_core/            shared, no service logic
  lib/shortener_core/
    application.ex              starts the Cassandra and Redis connections (not in tests)
    base62.ex                   encode, decode, random
    key_source.ex               behaviour + dispatcher; key_source/in_process.ex
    url.ex                      %Url{} struct
    url_store.ex                behaviour + dispatcher; url_store/{memory,cassandra}.ex
    cache.ex                    behaviour + dispatcher; cache/{memory,redis}.ex
    cassandra.ex                connection child spec (QUORUM default)
    cassandra/schema.ex         idempotent keyspace and table setup
    redis.ex                    connection child spec
  lib/mix/tasks/shortener.cassandra.setup.ex
  test/support/*_contract.ex    contract tests shared by fakes and real implementations
apps/write_api/                 POST /urls
  lib/write_api/{application,endpoint,router,error_json,link_params,shortener}.ex
  lib/write_api/controllers/{url,health}_controller.ex
  test/support/doubles.ex       failure doubles
apps/redirect_api/              GET /{code}
  lib/redirect_api/{application,endpoint,router,error_json,resolver}.ex
  lib/redirect_api/controllers/{redirect,health}_controller.ex
```

Run unit tests from the repo root with `mix test` (all apps) or from one app with `cd apps/<app> && mix test`. Integration tests: `INTEGRATION=1 mix test` with Cassandra and Redis running.

---

### Task 1: Umbrella, toolchain and the Cassandra and Redis containers

**Files:**
- Create: `.tool-versions`, `mix.exs`, `.formatter.exs`, `.gitignore`, `config/config.exs`, `config/dev.exs`, `config/prod.exs`, `config/test.exs`, `config/runtime.exs`
- Create: `apps/shortener_core/mix.exs`, `apps/shortener_core/.formatter.exs`, `apps/shortener_core/lib/shortener_core/application.ex`, `apps/shortener_core/test/test_helper.exs`
- Create: `docker-compose.yml` (Cassandra and Redis only for now)

**Interfaces:**
- Produces: the config keys every later task reads (`:shortener_core` keys `url_store`, `cache`, `key_source`, `start_clients`, `cassandra`, `redis_url`, `default_link_ttl`, `max_link_ttl`, `cache_ttl`, `negative_cache_ttl`; `:write_api` keys `base_url`, `max_key_attempts`). The `:integration` tag convention. Cassandra on `127.0.0.1:9042` and Redis on `127.0.0.1:6379`.

- [ ] **Step 1: Pin the toolchain**

Create `.tool-versions`:

```text
erlang 27.0
elixir 1.18.0-otp-27
```

Run: `elixir --version`
Expected: the last line reads `Elixir 1.18.0 (compiled with Erlang/OTP 27)`. If asdf reports the version is not installed, run `asdf install`.

- [ ] **Step 2: Create the umbrella files**

Create `mix.exs`:

```elixir
defmodule UrlShortener.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: []
    ]
  end
end
```

Create `.formatter.exs`:

```elixir
[
  inputs: ["mix.exs", "config/*.exs"],
  subdirectories: ["apps/*"]
]
```

Create `.gitignore`:

```text
# Mix build output and dependencies
/_build/
/deps/
*.ez
erl_crash.dump
.elixir_ls/
```

- [ ] **Step 3: Create the config files**

`config/config.exs` holds the defaults. The `write_api` and `redirect_api` entries refer to apps created in Tasks 7 and 8, so Mix prints a harmless "You have configured application :write_api ... not available" warning until then.

```elixir
import Config

config :logger, :default_formatter, metadata: [:request_id]

config :shortener_core,
  url_store: ShortenerCore.UrlStore.Cassandra,
  cache: ShortenerCore.Cache.Redis,
  key_source: ShortenerCore.KeySource.InProcess,
  start_clients: true,
  cassandra: [nodes: ["127.0.0.1:9042"], keyspace: "shortener", replication_factor: 1],
  redis_url: "redis://127.0.0.1:6379",
  # Seconds. 10 years is the default and the maximum link lifetime (ADR 0004).
  default_link_ttl: 315_360_000,
  max_link_ttl: 315_360_000,
  # Upper bound for a cached destination; the real TTL is also capped by the link's remaining TTL.
  cache_ttl: 3_600,
  # Short TTL for 404 and 410 entries (ADR 0003).
  negative_cache_ttl: 30

config :write_api, WriteApi.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {0, 0, 0, 0}, port: 4001],
  server: true,
  render_errors: [formats: [json: WriteApi.ErrorJSON], layout: false]

config :write_api,
  base_url: "http://localhost:4002",
  # Attempts to find an unclaimed generated key before returning 503 (ADR 0001).
  max_key_attempts: 3

config :redirect_api, RedirectApi.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {0, 0, 0, 0}, port: 4002],
  server: true,
  render_errors: [formats: [json: RedirectApi.ErrorJSON], layout: false]

import_config "#{config_env()}.exs"
```

`config/dev.exs` and `config/prod.exs` are empty for now:

```elixir
import Config
```

```elixir
import Config
```

`config/test.exs` swaps in the in-memory fakes and stops the real clients from starting. Connection details for integration tests can be overridden with `CASSANDRA_TEST_NODE` and `REDIS_TEST_URL`.

```elixir
import Config

config :logger, level: :warning

config :shortener_core,
  url_store: ShortenerCore.UrlStore.Memory,
  cache: ShortenerCore.Cache.Memory,
  start_clients: false,
  cassandra: [
    nodes: [System.get_env("CASSANDRA_TEST_NODE", "127.0.0.1:9042")],
    keyspace: "shortener_test",
    replication_factor: 1
  ]

config :write_api, WriteApi.Endpoint, server: false
config :redirect_api, RedirectApi.Endpoint, server: false

config :shortener_core, redis_url: System.get_env("REDIS_TEST_URL", "redis://127.0.0.1:6379")
```

`config/runtime.exs` reads the environment. These are the variables Compose sets later.

```elixir
import Config

if config_env() != :test do
  nodes =
    "CASSANDRA_NODES"
    |> System.get_env("127.0.0.1:9042")
    |> String.split(",", trim: true)

  config :shortener_core,
    cassandra: [
      nodes: nodes,
      keyspace: System.get_env("CASSANDRA_KEYSPACE", "shortener"),
      replication_factor: String.to_integer(System.get_env("CASSANDRA_REPLICATION_FACTOR", "1"))
    ],
    redis_url: System.get_env("REDIS_URL", "redis://127.0.0.1:6379")

  config :write_api,
    base_url: System.get_env("BASE_URL", "http://localhost:4002")

  config :write_api, WriteApi.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("WRITE_API_PORT", "4001"))],
    secret_key_base: System.get_env("SECRET_KEY_BASE", String.duplicate("a", 64))

  config :redirect_api, RedirectApi.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("REDIRECT_API_PORT", "4002"))],
    secret_key_base: System.get_env("SECRET_KEY_BASE", String.duplicate("a", 64))
end
```

- [ ] **Step 4: Create the `shortener_core` skeleton**

Create `apps/shortener_core/mix.exs`:

```elixir
defmodule ShortenerCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :shortener_core,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {ShortenerCore.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:xandra, "~> 0.20"},
      {:decimal, "~> 2.0"},
      {:redix, "~> 1.5"}
    ]
  end
end
```

Create `apps/shortener_core/.formatter.exs`:

```elixir
[
  inputs: ["*.{ex,exs}", "{config,lib,test}/**/*.{ex,exs}"]
]
```

Create `apps/shortener_core/lib/shortener_core/application.ex`. It names `ShortenerCore.Cassandra` and `ShortenerCore.Redis`, which Tasks 5 and 6 create; they are only started when `start_clients` is true, so tests are unaffected.

```elixir
defmodule ShortenerCore.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Tests swap in in-memory fakes and set start_clients: false.
    children =
      if Application.fetch_env!(:shortener_core, :start_clients) do
        [ShortenerCore.Cassandra, ShortenerCore.Redis]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: ShortenerCore.Supervisor)
  end
end
```

Create `apps/shortener_core/test/test_helper.exs`:

```elixir
# Integration tests need Cassandra and Redis (docker compose up -d cassandra redis).
# Run them with: INTEGRATION=1 mix test
exclude = if System.get_env("INTEGRATION") == "1", do: [], else: [:integration]

ExUnit.start(exclude: exclude)
```

- [ ] **Step 5: Fetch dependencies and compile**

Run: `mix deps.get && mix compile`
Expected: dependencies are fetched (xandra, decimal, redix, telemetry, nimble_options...), `mix.lock` is created, and `==> shortener_core` ends with `Generated shortener_core app`. Warnings about `:write_api` and `:redirect_api` not being available are expected.

Run: `mix test`
Expected: `There are no tests to run`.

- [ ] **Step 6: Create the Compose file with Cassandra and Redis**

Cassandra runs one node with a 512 MB heap, and Redis evicts with LRU (spec §5). Both publish their ports on localhost only, so integration tests can reach them.

Create `docker-compose.yml`:

```yaml
# Milestone 1 stack: Cassandra, Redis, write_api, redirect_api.
# Cassandra runs one node with RF=1 locally; production uses RF=3 (ADR 0003).
services:
  cassandra:
    image: cassandra:5
    environment:
      MAX_HEAP_SIZE: 512M
      HEAP_NEWSIZE: 128M
    ports:
      - "127.0.0.1:9042:9042"
    healthcheck:
      test: ["CMD-SHELL", "cqlsh -e 'describe keyspaces' >/dev/null 2>&1"]
      interval: 10s
      timeout: 10s
      retries: 30
      start_period: 30s

  redis:
    image: redis:7
    command: ["redis-server", "--maxmemory", "256mb", "--maxmemory-policy", "allkeys-lru"]
    ports:
      - "127.0.0.1:6379:6379"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 10
```

Run: `docker compose up -d --wait cassandra redis`
Expected: both containers reach `Healthy`. Cassandra takes about a minute to start.

Run: `docker compose exec cassandra cqlsh -e "select release_version from system.local"`
Expected: a `release_version` row starting with `5.`.

- [ ] **Step 7: Commit**

```bash
git add .tool-versions mix.exs mix.lock .formatter.exs .gitignore config apps/shortener_core docker-compose.yml
git commit -m "Scaffold umbrella, config and Cassandra and Redis containers"
```

---

### Task 2: Base62

**Files:**
- Create: `apps/shortener_core/lib/shortener_core/base62.ex`
- Test: `apps/shortener_core/test/shortener_core/base62_test.exs`

**Interfaces:**
- Produces: `ShortenerCore.Base62.encode(non_neg_integer) :: String.t()`, `decode(String.t()) :: {:ok, non_neg_integer} | :error`, `random(pos_integer) :: String.t()` (cryptographically random, no modulo bias). Task 3 uses `random/1`.

- [ ] **Step 1: Write the failing test**

Create `apps/shortener_core/test/shortener_core/base62_test.exs`:

```elixir
defmodule ShortenerCore.Base62Test do
  use ExUnit.Case, async: true

  alias ShortenerCore.Base62

  describe "encode/1" do
    test "encodes zero" do
      assert Base62.encode(0) == "0"
    end

    test "encodes known values" do
      assert Base62.encode(61) == "z"
      assert Base62.encode(62) == "10"
      assert Base62.encode(125) == "21"
    end
  end

  describe "decode/1" do
    test "round-trips with encode" do
      for n <- [0, 1, 61, 62, 3_844, 1_000_000, 62 ** 7 - 1] do
        assert Base62.decode(Base62.encode(n)) == {:ok, n}
      end
    end

    test "rejects invalid characters and the empty string" do
      assert Base62.decode("ab-c") == :error
      assert Base62.decode("") == :error
      assert Base62.decode("a b") == :error
    end
  end

  describe "random/1" do
    test "returns exactly the requested length of base62 characters" do
      for length <- [1, 7, 32] do
        code = Base62.random(length)
        assert byte_size(code) == length
        assert code =~ ~r/\A[0-9A-Za-z]+\z/
      end
    end

    test "does not repeat across many draws" do
      codes = for _ <- 1..1_000, do: Base62.random(7)
      assert length(Enum.uniq(codes)) == 1_000
    end
  end
end
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd apps/shortener_core && mix test test/shortener_core/base62_test.exs`
Expected: FAIL, `UndefinedFunctionError ... ShortenerCore.Base62.encode/1 is undefined (module ShortenerCore.Base62 is not available)`.

- [ ] **Step 3: Implement**

Create `apps/shortener_core/lib/shortener_core/base62.ex`:

```elixir
defmodule ShortenerCore.Base62 do
  @moduledoc """
  Base62 encoding and random code generation.

  The alphabet is `0-9`, `A-Z`, `a-z`.
  """

  @alphabet ~c"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
  @base 62

  # Bytes below this limit map to the alphabet without modulo bias (62 * 4 = 248).
  @unbiased_limit 248

  @doc "Encodes a non-negative integer as a base62 string."
  @spec encode(non_neg_integer()) :: String.t()
  def encode(0), do: "0"

  def encode(n) when is_integer(n) and n > 0 do
    n |> do_encode([]) |> List.to_string()
  end

  defp do_encode(0, acc), do: acc
  defp do_encode(n, acc), do: do_encode(div(n, @base), [Enum.at(@alphabet, rem(n, @base)) | acc])

  @doc "Decodes a base62 string. Returns `:error` for an empty string or an invalid character."
  @spec decode(String.t()) :: {:ok, non_neg_integer()} | :error
  def decode(""), do: :error

  def decode(string) when is_binary(string) do
    string
    |> String.to_charlist()
    |> Enum.reduce_while({:ok, 0}, fn char, {:ok, acc} ->
      case Enum.find_index(@alphabet, &(&1 == char)) do
        nil -> {:halt, :error}
        index -> {:cont, {:ok, acc * @base + index}}
      end
    end)
  end

  @doc "Returns a cryptographically random base62 string of exactly `length` characters."
  @spec random(pos_integer()) :: String.t()
  def random(length) when is_integer(length) and length > 0 do
    length |> take_chars([]) |> List.to_string()
  end

  defp take_chars(0, acc), do: acc

  defp take_chars(remaining, acc) do
    # Over-request bytes so one round almost always fills the code.
    bytes = :crypto.strong_rand_bytes(remaining * 2)

    {chars, left} =
      for <<byte <- bytes>>, byte < @unbiased_limit, reduce: {acc, remaining} do
        {chars, left} when left > 0 -> {[Enum.at(@alphabet, rem(byte, @base)) | chars], left - 1}
        {chars, 0} -> {chars, 0}
      end

    take_chars(left, chars)
  end
end
```

- [ ] **Step 4: Run it to see it pass**

Run: `cd apps/shortener_core && mix test test/shortener_core/base62_test.exs`
Expected: `6 tests, 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add apps/shortener_core/lib/shortener_core/base62.ex apps/shortener_core/test/shortener_core/base62_test.exs
git commit -m "Add Base62 encoding and random code generation"
```

---

### Task 3: KeySource behaviour and the in-process generator

**Files:**
- Create: `apps/shortener_core/lib/shortener_core/key_source.ex`, `apps/shortener_core/lib/shortener_core/key_source/in_process.ex`
- Create: `apps/shortener_core/test/support/key_source_contract.ex`
- Test: `apps/shortener_core/test/shortener_core/key_source/in_process_test.exs`

**Interfaces:**
- Consumes: `ShortenerCore.Base62.random/1`.
- Produces: behaviour `ShortenerCore.KeySource` with `next_key() :: {:ok, String.t()} | {:error, :unavailable}`; the module itself dispatches `next_key/0` to the module in `config :shortener_core, :key_source`. `ShortenerCore.KeySource.InProcess` implements it. `ShortenerCore.KeySourceContract` (`use ShortenerCore.KeySourceContract, source: Mod`) is reused by the KGS client in milestone 2.

- [ ] **Step 1: Write the contract and the test**

Create `apps/shortener_core/test/support/key_source_contract.ex`:

```elixir
defmodule ShortenerCore.KeySourceContract do
  @moduledoc """
  Behaviour contract for `ShortenerCore.KeySource` implementations (ADR 0001).

      use ShortenerCore.KeySourceContract, source: MySource
  """

  defmacro __using__(opts) do
    source = Keyword.fetch!(opts, :source)

    quote do
      @source unquote(source)

      test "next_key returns a 7-character base62 code" do
        assert {:ok, code} = @source.next_key()
        assert code =~ ~r/\A[0-9A-Za-z]{7}\z/
      end

      test "next_key does not repeat across many calls" do
        codes = for _ <- 1..500, do: elem(@source.next_key(), 1)
        assert length(Enum.uniq(codes)) == 500
      end
    end
  end
end
```

Create `apps/shortener_core/test/shortener_core/key_source/in_process_test.exs`:

```elixir
defmodule ShortenerCore.KeySource.InProcessTest do
  use ExUnit.Case, async: true
  use ShortenerCore.KeySourceContract, source: ShortenerCore.KeySource.InProcess
end
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd apps/shortener_core && mix test test/shortener_core/key_source`
Expected: FAIL, `ShortenerCore.KeySource.InProcess.next_key/0 is undefined (module ... is not available)`.

- [ ] **Step 3: Implement**

Create `apps/shortener_core/lib/shortener_core/key_source.ex`:

```elixir
defmodule ShortenerCore.KeySource do
  @moduledoc """
  Where `write_api` gets unique codes from (ADR 0001).

  The implementation is chosen by `config :shortener_core, :key_source`. Milestone 1 uses
  `ShortenerCore.KeySource.InProcess`; milestone 2 adds a KGS client behind the same behaviour.
  """

  @callback next_key() :: {:ok, String.t()} | {:error, :unavailable}

  @spec next_key() :: {:ok, String.t()} | {:error, :unavailable}
  def next_key, do: impl().next_key()

  defp impl, do: Application.fetch_env!(:shortener_core, :key_source)
end
```

Create `apps/shortener_core/lib/shortener_core/key_source/in_process.ex`:

```elixir
defmodule ShortenerCore.KeySource.InProcess do
  @moduledoc """
  Random 7-character base62 codes generated in the calling process.

  Early-milestone stand-in for KGS (ADR 0001). It is NOT collision-free: uniqueness comes
  from the `INSERT ... IF NOT EXISTS` claim in the write path.
  """

  @behaviour ShortenerCore.KeySource

  alias ShortenerCore.Base62

  @code_length 7

  @impl true
  def next_key, do: {:ok, Base62.random(@code_length)}
end
```

- [ ] **Step 4: Run it to see it pass**

Run: `cd apps/shortener_core && mix test test/shortener_core/key_source`
Expected: `2 tests, 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add apps/shortener_core/lib/shortener_core/key_source.ex apps/shortener_core/lib/shortener_core/key_source apps/shortener_core/test/support/key_source_contract.ex apps/shortener_core/test/shortener_core/key_source
git commit -m "Add KeySource behaviour with in-process generator"
```

---

### Task 4: Url struct, UrlStore behaviour and the in-memory store

**Files:**
- Create: `apps/shortener_core/lib/shortener_core/url.ex`, `apps/shortener_core/lib/shortener_core/url_store.ex`, `apps/shortener_core/lib/shortener_core/url_store/memory.ex`
- Create: `apps/shortener_core/test/support/url_store_contract.ex`
- Test: `apps/shortener_core/test/shortener_core/url_store/memory_test.exs`

**Interfaces:**
- Produces: `%ShortenerCore.Url{code, long_url, owner_id, is_custom_alias, created_at, expires_at}` (`long_url` is `nil` once expired). Behaviour `ShortenerCore.UrlStore`: `claim(Url.t) :: :ok | {:error, :taken | :unavailable}`, `put_destination(code, long_url, ttl_seconds) :: :ok | {:error, :unavailable}`, `fetch(code) :: {:ok, Url.t} | :not_found | {:error, :unavailable}`; the module dispatches the same three functions to `config :shortener_core, :url_store`. `ShortenerCore.UrlStore.Memory` is an `Agent` fake: tests start it with `start_supervised!(ShortenerCore.UrlStore.Memory)`, and it expires destinations on read like Cassandra. `ShortenerCore.UrlStoreContract` (`use ShortenerCore.UrlStoreContract, store: Mod`) is shared with Task 5.

- [ ] **Step 1: Write the contract and the test**

The contract encodes ADR 0004: a claimed code stays taken after its destination expires.

Create `apps/shortener_core/test/support/url_store_contract.ex`:

```elixir
defmodule ShortenerCore.UrlStoreContract do
  @moduledoc """
  Behaviour contract for `ShortenerCore.UrlStore` implementations (ADR 0004).

      use ShortenerCore.UrlStoreContract, store: MyStore
  """

  defmacro __using__(opts) do
    store = Keyword.fetch!(opts, :store)

    quote do
      alias ShortenerCore.Url

      @store unquote(store)

      defp new_url(attrs \\ []) do
        now = DateTime.utc_now()

        struct!(
          Url,
          Keyword.merge(
            [
              code: "t" <> ShortenerCore.Base62.random(8),
              owner_id: nil,
              is_custom_alias: false,
              created_at: now,
              expires_at: DateTime.add(now, 3_600)
            ],
            attrs
          )
        )
      end

      test "fetch returns :not_found for an unknown code" do
        assert @store.fetch("t" <> ShortenerCore.Base62.random(8)) == :not_found
      end

      test "a claimed code with no destination fetches with long_url nil" do
        url = new_url()
        assert @store.claim(url) == :ok
        assert {:ok, %Url{long_url: nil, code: code}} = @store.fetch(url.code)
        assert code == url.code
      end

      test "claim stores the metadata" do
        url = new_url(owner_id: "owner-1", is_custom_alias: true)
        assert @store.claim(url) == :ok

        assert {:ok, fetched} = @store.fetch(url.code)
        assert fetched.owner_id == "owner-1"
        assert fetched.is_custom_alias == true
        assert DateTime.diff(fetched.expires_at, url.expires_at, :second) == 0
      end

      test "claiming a taken code returns {:error, :taken} and keeps the first row" do
        first = new_url(owner_id: "first")
        assert @store.claim(first) == :ok
        assert @store.claim(%Url{first | owner_id: "second"}) == {:error, :taken}
        assert {:ok, %Url{owner_id: "first"}} = @store.fetch(first.code)
      end

      test "put_destination makes the long url readable" do
        url = new_url()
        assert @store.claim(url) == :ok
        assert @store.put_destination(url.code, "https://example.com/a?b=1", 3_600) == :ok
        assert {:ok, %Url{long_url: "https://example.com/a?b=1"}} = @store.fetch(url.code)
      end

      test "after the TTL the destination is gone but the code stays claimed (ADR 0004)" do
        url = new_url()
        assert @store.claim(url) == :ok
        assert @store.put_destination(url.code, "https://example.com", 1) == :ok
        assert {:ok, %Url{long_url: "https://example.com"}} = @store.fetch(url.code)

        Process.sleep(1_500)

        assert {:ok, %Url{long_url: nil}} = @store.fetch(url.code)
        assert @store.claim(url) == {:error, :taken}
      end
    end
  end
end
```

Create `apps/shortener_core/test/shortener_core/url_store/memory_test.exs`:

```elixir
defmodule ShortenerCore.UrlStore.MemoryTest do
  use ExUnit.Case, async: false
  use ShortenerCore.UrlStoreContract, store: ShortenerCore.UrlStore.Memory

  setup do
    start_supervised!(ShortenerCore.UrlStore.Memory)
    :ok
  end
end
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd apps/shortener_core && mix test test/shortener_core/url_store/memory_test.exs`
Expected: FAIL, `ShortenerCore.Url.__struct__/0 is undefined` or `ShortenerCore.UrlStore.Memory ... is not available`.

- [ ] **Step 3: Implement**

Create `apps/shortener_core/lib/shortener_core/url.ex`:

```elixir
defmodule ShortenerCore.Url do
  @moduledoc """
  One row of the `urls` table.

  `long_url` is `nil` once the link has expired: only that column carries the TTL, the rest
  of the row is the permanent claim on the code (ADR 0004).
  """

  @enforce_keys [:code, :owner_id, :is_custom_alias, :created_at, :expires_at]
  defstruct [:code, :long_url, :owner_id, :is_custom_alias, :created_at, :expires_at]

  @type t :: %__MODULE__{
          code: String.t(),
          long_url: String.t() | nil,
          owner_id: String.t() | nil,
          is_custom_alias: boolean(),
          created_at: DateTime.t(),
          expires_at: DateTime.t()
        }
end
```

Create `apps/shortener_core/lib/shortener_core/url_store.ex`:

```elixir
defmodule ShortenerCore.UrlStore do
  @moduledoc """
  Storage for short links. A link is written in two steps (ADR 0004):

    1. `claim/1` reserves the code permanently (no TTL).
    2. `put_destination/3` stores `long_url` with a TTL.

  Implementation chosen by `config :shortener_core, :url_store`.
  """

  alias ShortenerCore.Url

  @callback claim(Url.t()) :: :ok | {:error, :taken | :unavailable}
  @callback put_destination(
              code :: String.t(),
              long_url :: String.t(),
              ttl_seconds :: pos_integer()
            ) ::
              :ok | {:error, :unavailable}
  @callback fetch(code :: String.t()) :: {:ok, Url.t()} | :not_found | {:error, :unavailable}

  def claim(%Url{} = url), do: impl().claim(url)
  def put_destination(code, long_url, ttl), do: impl().put_destination(code, long_url, ttl)
  def fetch(code), do: impl().fetch(code)

  defp impl, do: Application.fetch_env!(:shortener_core, :url_store)
end
```

Create `apps/shortener_core/lib/shortener_core/url_store/memory.ex`:

```elixir
defmodule ShortenerCore.UrlStore.Memory do
  @moduledoc """
  In-memory `UrlStore` for unit tests. Start it with `start_supervised!(ShortenerCore.UrlStore.Memory)`.
  TTL expiry is checked on read against the system clock, like Cassandra's.
  """

  @behaviour ShortenerCore.UrlStore

  use Agent

  alias ShortenerCore.Url

  def start_link(_opts \\ []), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @impl true
  def claim(%Url{code: code} = url) do
    Agent.get_and_update(__MODULE__, fn rows ->
      if Map.has_key?(rows, code) do
        {{:error, :taken}, rows}
      else
        {:ok, Map.put(rows, code, %{url: url, destination: nil})}
      end
    end)
  end

  @impl true
  def put_destination(code, long_url, ttl) do
    deadline = System.monotonic_time(:millisecond) + ttl * 1_000

    Agent.update(__MODULE__, fn rows ->
      Map.update!(rows, code, &%{&1 | destination: {long_url, deadline}})
    end)
  end

  @impl true
  def fetch(code) do
    Agent.get(__MODULE__, fn rows ->
      case Map.fetch(rows, code) do
        :error ->
          :not_found

        {:ok, %{url: url, destination: destination}} ->
          {:ok, %Url{url | long_url: live(destination)}}
      end
    end)
  end

  defp live(nil), do: nil

  defp live({long_url, deadline}) do
    if System.monotonic_time(:millisecond) < deadline, do: long_url, else: nil
  end
end
```

- [ ] **Step 4: Run it to see it pass**

Run: `cd apps/shortener_core && mix test test/shortener_core/url_store/memory_test.exs`
Expected: `6 tests, 0 failures` (the expiry test takes about 1.5 seconds).

- [ ] **Step 5: Commit**

```bash
git add apps/shortener_core/lib/shortener_core/url.ex apps/shortener_core/lib/shortener_core/url_store.ex apps/shortener_core/lib/shortener_core/url_store apps/shortener_core/test/support/url_store_contract.ex apps/shortener_core/test/shortener_core/url_store/memory_test.exs
git commit -m "Add Url struct, UrlStore behaviour and in-memory store"
```

---

### Task 5: Cassandra connection, schema and UrlStore

**Files:**
- Create: `apps/shortener_core/lib/shortener_core/cassandra.ex`, `apps/shortener_core/lib/shortener_core/cassandra/schema.ex`, `apps/shortener_core/lib/shortener_core/url_store/cassandra.ex`, `apps/shortener_core/lib/mix/tasks/shortener.cassandra.setup.ex`
- Test: `apps/shortener_core/test/shortener_core/url_store/cassandra_test.exs` (tagged `:integration`)

**Interfaces:**
- Consumes: `ShortenerCore.UrlStore` behaviour, `ShortenerCore.Url`, `ShortenerCore.UrlStoreContract`.
- Produces: `ShortenerCore.Cassandra.child_spec(opts)` (registered name `ShortenerCore.Cassandra`, QUORUM default, accepts `:nodes` and `:keyspace` overrides), `ShortenerCore.Cassandra.conn/0`, `ShortenerCore.Cassandra.config/0`. `ShortenerCore.Cassandra.Schema.statements(keyspace, rf)` and `setup!/1` (idempotent, retries while Cassandra starts). `mix shortener.cassandra.setup`. `ShortenerCore.UrlStore.Cassandra` implements the behaviour. Task 9's `migrate` service runs the Mix task.

- [ ] **Step 1: Write the failing integration test**

It reuses the Task 4 contract, so the real store must behave exactly like the fake. The extra test checks that an unreachable node gives `{:error, :unavailable}` instead of crashing. `@moduletag :integration` must come before the `use` line, otherwise the contract's tests are not tagged.

Create `apps/shortener_core/test/shortener_core/url_store/cassandra_test.exs`:

```elixir
defmodule ShortenerCore.UrlStore.CassandraTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  use ShortenerCore.UrlStoreContract, store: ShortenerCore.UrlStore.Cassandra

  setup_all do
    ShortenerCore.Cassandra.Schema.setup!()
    :ok
  end

  setup do
    start_supervised!(ShortenerCore.Cassandra)
    :ok
  end

  test "returns {:error, :unavailable} when Cassandra cannot be reached" do
    url = new_url()
    stop_supervised!(ShortenerCore.Cassandra)

    start_supervised!(
      {ShortenerCore.Cassandra, nodes: ["127.0.0.1:1"], keyspace: "system"},
      id: :unreachable
    )

    assert ShortenerCore.UrlStore.Cassandra.claim(url) == {:error, :unavailable}
    assert ShortenerCore.UrlStore.Cassandra.fetch(url.code) == {:error, :unavailable}
  end
end
```

- [ ] **Step 2: Run it to see it fail**

Run: `docker compose up -d --wait cassandra redis` (if not running), then `cd apps/shortener_core && INTEGRATION=1 mix test test/shortener_core/url_store/cassandra_test.exs`
Expected: FAIL, `ShortenerCore.Cassandra.Schema.setup!/0 is undefined (module ... is not available)`.

- [ ] **Step 3: Implement the connection and schema**

Create `apps/shortener_core/lib/shortener_core/cassandra.ex`:

```elixir
defmodule ShortenerCore.Cassandra do
  @moduledoc """
  The shared Cassandra connection.

  ADR 0003: QUORUM is the default consistency for every statement and is set once, here.
  Call sites must not override it. Conditional statements add `serial_consistency: :serial`.
  """

  @conn __MODULE__

  @doc "Name the connection is registered under."
  def conn, do: @conn

  @doc "Child spec for the supervision tree. `opts` override the application config."
  def child_spec(opts \\ []) do
    config = Keyword.merge(config(), opts)

    xandra_opts = [
      name: @conn,
      nodes: Keyword.fetch!(config, :nodes),
      keyspace: Keyword.fetch!(config, :keyspace),
      default_consistency: :quorum
    ]

    %{id: @conn, start: {Xandra, :start_link, [xandra_opts]}}
  end

  def config, do: Application.fetch_env!(:shortener_core, :cassandra)
end
```

Create `apps/shortener_core/lib/shortener_core/cassandra/schema.ex`:

```elixir
defmodule ShortenerCore.Cassandra.Schema do
  @moduledoc """
  Idempotent schema setup for the `shortener` keyspace. Run with `mix shortener.cassandra.setup`.

  The Key DB tables (`kgs` keyspace, ADR 0002) are added in milestone 2.
  """

  @keyspace_format ~r/\A[a-z][a-z0-9_]{0,47}\z/
  @attempts 30
  @retry_delay_ms 2_000

  @doc "CQL statements that create the keyspace and tables."
  @spec statements(keyspace :: String.t(), replication_factor :: pos_integer()) :: [String.t()]
  def statements(keyspace, replication_factor) do
    if not Regex.match?(@keyspace_format, keyspace) do
      raise ArgumentError, "invalid keyspace name: #{inspect(keyspace)}"
    end

    [
      """
      CREATE KEYSPACE IF NOT EXISTS #{keyspace}
      WITH replication = {'class': 'SimpleStrategy', 'replication_factor': #{replication_factor}}
      """,
      """
      CREATE TABLE IF NOT EXISTS #{keyspace}.urls (
        code text PRIMARY KEY,
        long_url text,
        owner_id text,
        is_custom_alias boolean,
        created_at timestamp,
        expires_at timestamp
      )
      """
    ]
  end

  @doc """
  Creates the keyspace and tables, retrying while Cassandra starts up.
  Uses its own connection because the application connection needs the keyspace to exist.
  """
  @spec setup!(keyword()) :: :ok
  def setup!(config \\ ShortenerCore.Cassandra.config()) do
    {:ok, _} = Application.ensure_all_started(:xandra)
    {:ok, conn} = Xandra.start_link(nodes: Keyword.fetch!(config, :nodes))

    try do
      statements(Keyword.fetch!(config, :keyspace), Keyword.fetch!(config, :replication_factor))
      |> Enum.each(&execute_with_retry!(conn, &1, @attempts))
    after
      GenServer.stop(conn)
    end
  end

  defp execute_with_retry!(conn, statement, attempts_left) do
    case Xandra.execute(conn, statement, []) do
      {:ok, _} ->
        :ok

      {:error, error} when attempts_left > 1 ->
        IO.puts("Cassandra not ready (#{Exception.message(error)}), retrying...")
        Process.sleep(@retry_delay_ms)
        execute_with_retry!(conn, statement, attempts_left - 1)

      {:error, error} ->
        raise "Cassandra schema setup failed: #{Exception.message(error)}"
    end
  end
end
```

Create `apps/shortener_core/lib/mix/tasks/shortener.cassandra.setup.ex`:

```elixir
defmodule Mix.Tasks.Shortener.Cassandra.Setup do
  @shortdoc "Creates the Cassandra keyspace and tables (idempotent)"
  @moduledoc "Creates the Cassandra keyspace and tables for the URL shortener. Safe to run repeatedly."

  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.config")
    ShortenerCore.Cassandra.Schema.setup!()
    Mix.shell().info("Cassandra schema is ready.")
  end
end
```

- [ ] **Step 4: Implement the store**

Create `apps/shortener_core/lib/shortener_core/url_store/cassandra.ex`:

```elixir
defmodule ShortenerCore.UrlStore.Cassandra do
  @moduledoc """
  `UrlStore` on Cassandra.

  ADR 0004: `claim/1` is an `INSERT ... IF NOT EXISTS` with no TTL, `put_destination/3` is an
  `UPDATE ... USING TTL` on `long_url` only. ADR 0003: all statements run at QUORUM (the
  connection default); the conditional claim adds serial consistency SERIAL.
  """

  @behaviour ShortenerCore.UrlStore

  alias ShortenerCore.{Cassandra, Url}

  @claim """
  INSERT INTO urls (code, owner_id, is_custom_alias, created_at, expires_at)
  VALUES (?, ?, ?, ?, ?) IF NOT EXISTS
  """

  @put_destination "UPDATE urls USING TTL ? SET long_url = ? WHERE code = ?"

  @fetch """
  SELECT code, long_url, owner_id, is_custom_alias, created_at, expires_at
  FROM urls WHERE code = ?
  """

  @impl true
  def claim(%Url{} = url) do
    params = [url.code, url.owner_id, url.is_custom_alias, url.created_at, url.expires_at]

    case execute(@claim, params, serial_consistency: :serial) do
      {:ok, page} ->
        case Enum.to_list(page) do
          [%{"[applied]" => true}] -> :ok
          _ -> {:error, :taken}
        end

      {:error, _} ->
        # A timed-out claim may or may not have applied; the caller treats the code as burned.
        {:error, :unavailable}
    end
  end

  @impl true
  def put_destination(code, long_url, ttl) do
    case execute(@put_destination, [ttl, long_url, code], []) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :unavailable}
    end
  end

  @impl true
  def fetch(code) do
    case execute(@fetch, [code], []) do
      {:ok, page} ->
        case Enum.to_list(page) do
          [] -> :not_found
          [row] -> {:ok, to_url(row)}
        end

      {:error, _} ->
        {:error, :unavailable}
    end
  end

  defp execute(statement, params, opts) do
    with {:ok, prepared} <- Xandra.prepare(Cassandra.conn(), statement) do
      Xandra.execute(Cassandra.conn(), prepared, params, opts)
    end
  end

  defp to_url(row) do
    %Url{
      code: row["code"],
      long_url: row["long_url"],
      owner_id: row["owner_id"],
      is_custom_alias: row["is_custom_alias"],
      created_at: row["created_at"],
      expires_at: row["expires_at"]
    }
  end
end
```

- [ ] **Step 5: Run it to see it pass**

Run: `cd apps/shortener_core && INTEGRATION=1 mix test test/shortener_core/url_store/cassandra_test.exs`
Expected: `7 tests, 0 failures`.

Run: `mix test`
Expected: the Cassandra tests are skipped: `... tests, 0 failures, 7 excluded`.

- [ ] **Step 6: Commit**

```bash
git add apps/shortener_core/lib apps/shortener_core/test/shortener_core/url_store/cassandra_test.exs
git commit -m "Add Cassandra connection, schema setup and UrlStore"
```

---

### Task 6: Cache behaviour, in-memory cache and Redis cache

**Files:**
- Create: `apps/shortener_core/lib/shortener_core/cache.ex`, `apps/shortener_core/lib/shortener_core/cache/memory.ex`, `apps/shortener_core/lib/shortener_core/cache/redis.ex`, `apps/shortener_core/lib/shortener_core/redis.ex`
- Create: `apps/shortener_core/test/support/cache_contract.ex`
- Test: `apps/shortener_core/test/shortener_core/cache/memory_test.exs`, `apps/shortener_core/test/shortener_core/cache/redis_test.exs` (tagged `:integration`)

**Interfaces:**
- Produces: type `ShortenerCore.Cache.entry :: {:url, String.t} | :not_found | :gone`. Behaviour `ShortenerCore.Cache`: `get(code) :: {:ok, entry} | :miss | {:error, :unavailable}`, `put(code, entry, ttl_seconds) :: :ok | {:error, :unavailable}`, `delete(code) :: :ok | {:error, :unavailable}`; the module dispatches to `config :shortener_core, :cache`. `ShortenerCore.Cache.Memory` (Agent fake, `start_supervised!`, plus `Memory.ttl(code)` to read the last TTL passed to `put/3`). `ShortenerCore.Cache.Redis`, `ShortenerCore.Redis.child_spec(opts)` (name `ShortenerCore.Redis`, accepts `:url`).

- [ ] **Step 1: Write the contract and the tests**

Create `apps/shortener_core/test/support/cache_contract.ex`:

```elixir
defmodule ShortenerCore.CacheContract do
  @moduledoc """
  Behaviour contract for `ShortenerCore.Cache` implementations.

      use ShortenerCore.CacheContract, cache: MyCache
  """

  defmacro __using__(opts) do
    cache = Keyword.fetch!(opts, :cache)

    quote do
      @cache unquote(cache)

      defp code, do: "c" <> ShortenerCore.Base62.random(8)

      test "get on an unknown code is a miss" do
        assert @cache.get(code()) == :miss
      end

      test "stores and returns a destination" do
        code = code()
        assert @cache.put(code, {:url, "https://example.com/x?y=1"}, 60) == :ok
        assert @cache.get(code) == {:ok, {:url, "https://example.com/x?y=1"}}
      end

      test "stores and returns negative entries" do
        a = code()
        b = code()
        assert @cache.put(a, :not_found, 60) == :ok
        assert @cache.put(b, :gone, 60) == :ok
        assert @cache.get(a) == {:ok, :not_found}
        assert @cache.get(b) == {:ok, :gone}
      end

      test "delete removes an entry and is safe on a missing one" do
        code = code()
        assert @cache.put(code, :not_found, 60) == :ok
        assert @cache.delete(code) == :ok
        assert @cache.get(code) == :miss
        assert @cache.delete(code) == :ok
      end

      test "a destination that looks like a negative marker is returned as a destination" do
        code = code()
        assert @cache.put(code, {:url, "N"}, 60) == :ok
        assert @cache.get(code) == {:ok, {:url, "N"}}
      end
    end
  end
end
```

Create `apps/shortener_core/test/shortener_core/cache/memory_test.exs`:

```elixir
defmodule ShortenerCore.Cache.MemoryTest do
  use ExUnit.Case, async: false
  use ShortenerCore.CacheContract, cache: ShortenerCore.Cache.Memory

  setup do
    start_supervised!(ShortenerCore.Cache.Memory)
    :ok
  end
end
```

Create `apps/shortener_core/test/shortener_core/cache/redis_test.exs`:

```elixir
defmodule ShortenerCore.Cache.RedisTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  use ShortenerCore.CacheContract, cache: ShortenerCore.Cache.Redis

  setup do
    start_supervised!(ShortenerCore.Redis)
    :ok
  end

  test "put sets the TTL on the key" do
    code = code()
    assert @cache.put(code, {:url, "https://example.com"}, 120) == :ok
    assert {:ok, ttl} = Redix.command(ShortenerCore.Redis.conn(), ["TTL", "url:" <> code])
    assert ttl in 119..120
  end

  test "returns {:error, :unavailable} when Redis cannot be reached" do
    stop_supervised!(ShortenerCore.Redis)
    start_supervised!({ShortenerCore.Redis, url: "redis://127.0.0.1:1"}, id: :unreachable)

    assert @cache.get(code()) == {:error, :unavailable}
    assert @cache.put(code(), :not_found, 60) == {:error, :unavailable}
    assert @cache.delete(code()) == {:error, :unavailable}
  end
end
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd apps/shortener_core && mix test test/shortener_core/cache/memory_test.exs`
Expected: FAIL, `ShortenerCore.Cache.Memory ... is not available`.

- [ ] **Step 3: Implement the behaviour and the fake**

Create `apps/shortener_core/lib/shortener_core/cache.ex`:

```elixir
defmodule ShortenerCore.Cache do
  @moduledoc """
  Cache-aside cache for redirects. One entry per code, either a destination or a negative result:

    * `{:url, long_url}` - redirect target
    * `:not_found` - no such code (404)
    * `:gone` - the link expired (410)

  Implementation chosen by `config :shortener_core, :cache`.
  """

  @type entry :: {:url, String.t()} | :not_found | :gone

  @callback get(code :: String.t()) :: {:ok, entry()} | :miss | {:error, :unavailable}
  @callback put(code :: String.t(), entry(), ttl_seconds :: pos_integer()) ::
              :ok | {:error, :unavailable}
  @callback delete(code :: String.t()) :: :ok | {:error, :unavailable}

  def get(code), do: impl().get(code)
  def put(code, entry, ttl), do: impl().put(code, entry, ttl)
  def delete(code), do: impl().delete(code)

  defp impl, do: Application.fetch_env!(:shortener_core, :cache)
end
```

Create `apps/shortener_core/lib/shortener_core/cache/memory.ex`:

```elixir
defmodule ShortenerCore.Cache.Memory do
  @moduledoc """
  In-memory `Cache` for unit tests. Start it with `start_supervised!(ShortenerCore.Cache.Memory)`.
  It records the TTL passed to `put/3` so tests can assert on it; entries never expire.
  """

  @behaviour ShortenerCore.Cache

  use Agent

  def start_link(_opts \\ []), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @doc "TTL in seconds that `put/3` was last called with for `code`, or `nil`."
  def ttl(code) do
    Agent.get(__MODULE__, fn entries ->
      case Map.fetch(entries, code) do
        {:ok, {_entry, ttl}} -> ttl
        :error -> nil
      end
    end)
  end

  @impl true
  def get(code) do
    Agent.get(__MODULE__, fn entries ->
      case Map.fetch(entries, code) do
        {:ok, {entry, _ttl}} -> {:ok, entry}
        :error -> :miss
      end
    end)
  end

  @impl true
  def put(code, entry, ttl), do: Agent.update(__MODULE__, &Map.put(&1, code, {entry, ttl}))

  @impl true
  def delete(code), do: Agent.update(__MODULE__, &Map.delete(&1, code))
end
```

Run: `cd apps/shortener_core && mix test test/shortener_core/cache/memory_test.exs`
Expected: `5 tests, 0 failures`.

- [ ] **Step 4: Implement Redis**

Create `apps/shortener_core/lib/shortener_core/redis.ex`:

```elixir
defmodule ShortenerCore.Redis do
  @moduledoc "The shared Redis connection."

  @conn __MODULE__

  def conn, do: @conn

  @doc "Child spec for the supervision tree. `opts` override the application config."
  def child_spec(opts \\ []) do
    url = Keyword.get(opts, :url, Application.fetch_env!(:shortener_core, :redis_url))

    %{id: @conn, start: {Redix, :start_link, [url, [name: @conn]]}}
  end
end
```

Create `apps/shortener_core/lib/shortener_core/cache/redis.ex`:

```elixir
defmodule ShortenerCore.Cache.Redis do
  @moduledoc """
  Redis-backed `Cache`. Values are stored as `"U:<url>"`, `"N"` (not found) or `"G"` (gone).
  A Redis error is reported as `{:error, :unavailable}`; callers fall back to Cassandra.
  """

  @behaviour ShortenerCore.Cache

  alias ShortenerCore.Redis

  @prefix "url:"

  @impl true
  def get(code) do
    case Redix.command(Redis.conn(), ["GET", key(code)]) do
      {:ok, nil} -> :miss
      {:ok, "U:" <> url} -> {:ok, {:url, url}}
      {:ok, "N"} -> {:ok, :not_found}
      {:ok, "G"} -> {:ok, :gone}
      {:ok, _unknown} -> :miss
      {:error, _} -> {:error, :unavailable}
    end
  end

  @impl true
  def put(code, entry, ttl) when is_integer(ttl) and ttl > 0 do
    case Redix.command(Redis.conn(), ["SET", key(code), encode(entry), "EX", ttl]) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :unavailable}
    end
  end

  @impl true
  def delete(code) do
    case Redix.command(Redis.conn(), ["DEL", key(code)]) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :unavailable}
    end
  end

  defp key(code), do: @prefix <> code

  defp encode({:url, url}), do: "U:" <> url
  defp encode(:not_found), do: "N"
  defp encode(:gone), do: "G"
end
```

- [ ] **Step 5: Run the integration tests**

Run: `cd apps/shortener_core && INTEGRATION=1 mix test test/shortener_core/cache`
Expected: `12 tests, 0 failures` (5 for the fake, 7 for Redis).

Run: `mix test` from the repo root.
Expected: `33 tests, 0 failures, 14 excluded` for `shortener_core`.

- [ ] **Step 6: Commit**

```bash
git add apps/shortener_core/lib apps/shortener_core/test
git commit -m "Add Cache behaviour with in-memory and Redis implementations"
```

---

### Task 7: write_api (`POST /urls`)

**Files:**
- Create: `apps/write_api/mix.exs`, `apps/write_api/.formatter.exs`, `apps/write_api/test/test_helper.exs`
- Create: `apps/write_api/lib/write_api/{application,endpoint,router,error_json,link_params,shortener}.ex`, `apps/write_api/lib/write_api/controllers/{url_controller,health_controller}.ex`
- Test: `apps/write_api/test/support/doubles.ex`, `apps/write_api/test/write_api/url_controller_test.exs`

**Interfaces:**
- Consumes: `ShortenerCore.KeySource.next_key/0`, `ShortenerCore.UrlStore.{claim,put_destination}/…`, `ShortenerCore.Cache.delete/1`, `%ShortenerCore.Url{}`, config keys from Task 1.
- Produces: `POST /urls` with body `{"url": ..., "custom_alias": ..., "ttl_seconds": ...}`: 201 `{"code", "short_url", "expires_at"}`, 409 `alias_taken`, 422 `invalid_url | invalid_alias | invalid_ttl`, 503 `unavailable`, 400 and 415 for bad bodies. `GET /health` returns `{"status":"ok"}`. `WriteApi.Shortener.create(params, now)` returns `{:ok, %{code, short_url, expires_at}} | {:error, :invalid_url | :invalid_alias | :invalid_ttl | :alias_taken | :unavailable}`. Port 4001.

- [ ] **Step 1: Create the app skeleton**

Create `apps/write_api/mix.exs`:

```elixir
defmodule WriteApi.MixProject do
  use Mix.Project

  def project do
    [
      app: :write_api,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {WriteApi.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:shortener_core, in_umbrella: true},
      {:phoenix, "~> 1.7"},
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.4"}
    ]
  end
end
```

Create `apps/write_api/.formatter.exs`:

```elixir
[
  import_deps: [:phoenix],
  inputs: ["*.{ex,exs}", "{config,lib,test}/**/*.{ex,exs}"]
]
```

Create `apps/write_api/test/test_helper.exs`:

```elixir
ExUnit.start()
```

Run: `mix deps.get`
Expected: phoenix, bandit, jason, plug and their dependencies are fetched and `mix.lock` is updated.

- [ ] **Step 2: Write the failure doubles and the tests**

The in-memory fakes cannot fail, so the doubles cover Cassandra down, a failure between the two write steps, Redis down, and a key source that returns scripted keys to provoke clashes.

Create `apps/write_api/test/support/doubles.ex`:

```elixir
defmodule WriteApi.Doubles do
  @moduledoc "Test doubles for the failure cases the in-memory fakes cannot produce."

  defmodule ScriptedKeySource do
    @moduledoc "Returns the keys it was started with, in order. Start with `start_supervised!({ScriptedKeySource, keys})`."
    @behaviour ShortenerCore.KeySource
    use Agent

    def start_link(keys), do: Agent.start_link(fn -> keys end, name: __MODULE__)

    @impl true
    def next_key do
      Agent.get_and_update(__MODULE__, fn
        [key | rest] -> {{:ok, key}, rest}
        [] -> {{:error, :unavailable}, []}
      end)
    end
  end

  defmodule DownStore do
    @moduledoc "Cassandra is unreachable."
    @behaviour ShortenerCore.UrlStore
    @impl true
    def claim(_url), do: {:error, :unavailable}
    @impl true
    def put_destination(_code, _url, _ttl), do: {:error, :unavailable}
    @impl true
    def fetch(_code), do: {:error, :unavailable}
  end

  defmodule DestinationFailsStore do
    @moduledoc "The claim works, the second write step fails: a crash between the two steps."
    @behaviour ShortenerCore.UrlStore
    alias ShortenerCore.UrlStore.Memory
    @impl true
    def claim(url), do: Memory.claim(url)
    @impl true
    def put_destination(_code, _url, _ttl), do: {:error, :unavailable}
    @impl true
    def fetch(code), do: Memory.fetch(code)
  end

  defmodule DownCache do
    @moduledoc "Redis is unreachable."
    @behaviour ShortenerCore.Cache
    @impl true
    def get(_code), do: {:error, :unavailable}
    @impl true
    def put(_code, _entry, _ttl), do: {:error, :unavailable}
    @impl true
    def delete(_code), do: {:error, :unavailable}
  end

  @doc "Swaps an application env value for the duration of the test."
  def swap_env(app, key, value) do
    old = Application.fetch_env!(app, key)
    Application.put_env(app, key, value)
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(app, key, old) end)
  end
end
```

Create `apps/write_api/test/write_api/url_controller_test.exs`. The `post_json/1` helper sends real JSON with a `content-type` header so the endpoint's parser runs. Errors raised before a controller are checked with `assert_error_sent`, which also proves `render_errors` returns JSON.

```elixir
defmodule WriteApi.UrlControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ShortenerCore.{Cache, UrlStore}
  alias WriteApi.Doubles
  alias WriteApi.Doubles.{DestinationFailsStore, DownCache, DownStore, ScriptedKeySource}

  @endpoint WriteApi.Endpoint

  setup do
    start_supervised!(UrlStore.Memory)
    start_supervised!(Cache.Memory)
    :ok
  end

  defp post_json(body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/urls", if(is_binary(body), do: body, else: Jason.encode!(body)))
  end

  describe "POST /urls with a generated code" do
    test "returns 201 with a 7-character code, the short URL and the expiry" do
      conn = post_json(%{"url" => "https://example.com/some/path?q=1"})

      assert %{"code" => code, "short_url" => short_url, "expires_at" => expires_at} =
               json_response(conn, 201)

      assert code =~ ~r/\A[0-9A-Za-z]{7}\z/
      assert short_url == "http://localhost:4002/" <> code
      assert {:ok, _, 0} = DateTime.from_iso8601(expires_at)
    end

    test "stores the destination so it can be fetched" do
      %{"code" => code} = json_response(post_json(%{"url" => "https://example.com/a"}), 201)

      assert {:ok, %{long_url: "https://example.com/a", is_custom_alias: false}} =
               UrlStore.fetch(code)
    end

    test "does not deduplicate: the same URL gets a new code each time" do
      body = %{"url" => "https://example.com/same"}
      %{"code" => a} = json_response(post_json(body), 201)
      %{"code" => b} = json_response(post_json(body), 201)
      assert a != b
    end

    test "honours ttl_seconds for the expiry" do
      before = DateTime.utc_now()
      conn = post_json(%{"url" => "https://example.com", "ttl_seconds" => 120})
      %{"expires_at" => expires_at} = json_response(conn, 201)
      {:ok, expires_at, 0} = DateTime.from_iso8601(expires_at)
      assert DateTime.diff(expires_at, before) in 119..122
    end
  end

  describe "POST /urls with a custom alias" do
    test "uses the alias as the code" do
      conn = post_json(%{"url" => "https://example.com", "custom_alias" => "my-link_1"})

      assert %{"code" => "my-link_1", "short_url" => "http://localhost:4002/my-link_1"} =
               json_response(conn, 201)

      assert {:ok, %{is_custom_alias: true}} = UrlStore.fetch("my-link_1")
    end

    test "a taken alias returns 409 and keeps the first destination" do
      body = %{"url" => "https://example.com/first", "custom_alias" => "taken"}
      assert json_response(post_json(body), 201)

      conn = post_json(%{body | "url" => "https://example.com/second"})
      assert %{"error" => "alias_taken"} = json_response(conn, 409)
      assert {:ok, %{long_url: "https://example.com/first"}} = UrlStore.fetch("taken")
    end

    test "clears a negative cache entry for the alias" do
      :ok = Cache.put("later", :not_found, 30)

      assert json_response(
               post_json(%{"url" => "https://example.com", "custom_alias" => "later"}),
               201
             )

      assert Cache.get("later") == :miss
    end

    test "still succeeds when the cache is down" do
      Doubles.swap_env(:shortener_core, :cache, DownCache)
      conn = post_json(%{"url" => "https://example.com", "custom_alias" => "nocache"})
      assert json_response(conn, 201)
    end
  end

  describe "a generated key that clashes with an existing alias (ADR 0001)" do
    setup do
      Doubles.swap_env(:shortener_core, :key_source, ScriptedKeySource)
      :ok
    end

    test "is discarded and the next key is used" do
      start_supervised!({ScriptedKeySource, ["clash01", "fresh01"]})

      assert json_response(
               post_json(%{"url" => "https://example.com", "custom_alias" => "clash01"}),
               201
             )

      conn = post_json(%{"url" => "https://example.com/other"})
      assert %{"code" => "fresh01"} = json_response(conn, 201)
    end

    test "returns 503 after 3 clashes in a row" do
      start_supervised!({ScriptedKeySource, ["aaa0001", "aaa0002", "aaa0003", "fresh01"]})

      for alias_name <- ["aaa0001", "aaa0002", "aaa0003"] do
        assert json_response(
                 post_json(%{"url" => "https://example.com", "custom_alias" => alias_name}),
                 201
               )
      end

      conn = post_json(%{"url" => "https://example.com/other"})
      assert %{"error" => "unavailable"} = json_response(conn, 503)
    end

    test "returns 503 when the key source has nothing left" do
      start_supervised!({ScriptedKeySource, []})
      assert json_response(post_json(%{"url" => "https://example.com"}), 503)
    end

    test "custom aliases still work when the key source is down" do
      start_supervised!({ScriptedKeySource, []})

      assert json_response(
               post_json(%{"url" => "https://example.com", "custom_alias" => "stillworks"}),
               201
             )
    end
  end

  describe "storage failures" do
    test "returns 503 when Cassandra is down" do
      Doubles.swap_env(:shortener_core, :url_store, DownStore)

      assert %{"error" => "unavailable"} =
               json_response(post_json(%{"url" => "https://example.com"}), 503)
    end

    test "a failure after the claim returns 503 and burns the code (ADR 0004)" do
      Doubles.swap_env(:shortener_core, :url_store, DestinationFailsStore)

      conn = post_json(%{"url" => "https://example.com", "custom_alias" => "burned"})
      assert json_response(conn, 503)

      assert {:ok, %{long_url: nil}} = UrlStore.Memory.fetch("burned")

      assert UrlStore.Memory.claim(%ShortenerCore.Url{
               code: "burned",
               owner_id: nil,
               is_custom_alias: true,
               created_at: DateTime.utc_now(),
               expires_at: DateTime.utc_now()
             }) == {:error, :taken}
    end
  end

  describe "validation" do
    for {name, body} <- [
          {"a missing url", %{}},
          {"a non-string url", %{"url" => 123}},
          {"a null url", %{"url" => nil}},
          {"an unsupported scheme", %{"url" => "ftp://example.com/file"}},
          {"javascript: urls", %{"url" => "javascript:alert(1)"}},
          {"a url with no host", %{"url" => "https:///path"}},
          {"a url with a newline (header injection)",
           %{"url" => "https://example.com/\r\nSet-Cookie: a=b"}},
          {"a url with a space", %{"url" => "https://example.com/a b"}},
          {"a url over 2048 bytes",
           %{"url" => "https://example.com/" <> String.duplicate("a", 2_100)}}
        ] do
      test "rejects #{name} with 422 invalid_url" do
        conn = post_json(unquote(Macro.escape(body)))
        assert %{"error" => "invalid_url"} = json_response(conn, 422)
      end
    end

    for {name, alias_name} <- [
          {"an alias that is too short", "ab"},
          {"an alias that is too long", String.duplicate("a", 33)},
          {"an alias with a slash", "a/b"},
          {"an alias with a space", "a b"},
          {"a reserved alias", "health"},
          {"a reserved alias in another case", "URLS"},
          {"a non-string alias", 42}
        ] do
      test "rejects #{name} with 422 invalid_alias" do
        body = %{
          "url" => "https://example.com",
          "custom_alias" => unquote(Macro.escape(alias_name))
        }

        assert %{"error" => "invalid_alias"} = json_response(post_json(body), 422)
      end
    end

    for {name, ttl} <- [
          {"a zero ttl", 0},
          {"a negative ttl", -5},
          {"a float ttl", 1.5},
          {"a string ttl", "60"},
          {"a ttl above the maximum", 315_360_001}
        ] do
      test "rejects #{name} with 422 invalid_ttl" do
        body = %{"url" => "https://example.com", "ttl_seconds" => unquote(ttl)}
        assert %{"error" => "invalid_ttl"} = json_response(post_json(body), 422)
      end
    end

    test "rejects a JSON array body" do
      assert %{"error" => "invalid_url"} = json_response(post_json("[1,2,3]"), 422)
    end

    test "malformed JSON returns 400 with a JSON body" do
      {400, _headers, body} =
        assert_error_sent 400, fn ->
          build_conn()
          |> put_req_header("content-type", "application/json")
          |> post("/urls", "{not json")
        end

      assert Jason.decode!(body) == %{"error" => "Bad Request"}
    end

    test "a non-JSON content type returns 415 with a JSON body" do
      {415, _headers, body} =
        assert_error_sent 415, fn ->
          build_conn() |> put_req_header("content-type", "text/plain") |> post("/urls", "hello")
        end

      assert Jason.decode!(body) == %{"error" => "Unsupported Media Type"}
    end
  end

  test "GET /health returns ok" do
    assert %{"status" => "ok"} = build_conn() |> get("/health") |> json_response(200)
  end
end
```

- [ ] **Step 3: Run them to see them fail**

Run: `cd apps/write_api && mix test`
Expected: FAIL. Every test errors because `WriteApi.Endpoint` is undefined.

- [ ] **Step 4: Implement validation and the write flow**

Create `apps/write_api/lib/write_api/link_params.ex`:

```elixir
defmodule WriteApi.LinkParams do
  @moduledoc """
  Validates and normalises the body of `POST /urls`.

  Body: `{"url": "https://...", "custom_alias": "my-link", "ttl_seconds": 3600}`.
  `custom_alias` and `ttl_seconds` are optional.
  """

  @max_url_length 2_048
  @alias_format ~r/\A[0-9A-Za-z_-]{3,32}\z/
  # Paths the services own, so an alias must not shadow them.
  @reserved_aliases ~w(health urls stats)
  # Whitespace and control characters: they would break, or inject into, the Location header.
  @forbidden_in_url ~r/[\x00-\x20\x7f]/

  @type t :: %{url: String.t(), custom_alias: String.t() | nil, ttl_seconds: pos_integer()}
  @type error :: :invalid_url | :invalid_alias | :invalid_ttl

  @spec parse(map()) :: {:ok, t()} | {:error, error()}
  def parse(params) when is_map(params) do
    with {:ok, url} <- parse_url(params["url"]),
         {:ok, custom_alias} <- parse_alias(params["custom_alias"]),
         {:ok, ttl} <- parse_ttl(params["ttl_seconds"]) do
      {:ok, %{url: url, custom_alias: custom_alias, ttl_seconds: ttl}}
    end
  end

  defp parse_url(url) when is_binary(url) and byte_size(url) <= @max_url_length do
    uri = URI.parse(url)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
         not Regex.match?(@forbidden_in_url, url) do
      {:ok, url}
    else
      {:error, :invalid_url}
    end
  end

  defp parse_url(_), do: {:error, :invalid_url}

  defp parse_alias(nil), do: {:ok, nil}

  defp parse_alias(custom_alias) when is_binary(custom_alias) do
    if Regex.match?(@alias_format, custom_alias) and
         String.downcase(custom_alias) not in @reserved_aliases do
      {:ok, custom_alias}
    else
      {:error, :invalid_alias}
    end
  end

  defp parse_alias(_), do: {:error, :invalid_alias}

  defp parse_ttl(nil), do: {:ok, Application.fetch_env!(:shortener_core, :default_link_ttl)}

  defp parse_ttl(ttl) when is_integer(ttl) do
    if ttl >= 1 and ttl <= Application.fetch_env!(:shortener_core, :max_link_ttl) do
      {:ok, ttl}
    else
      {:error, :invalid_ttl}
    end
  end

  defp parse_ttl(_), do: {:error, :invalid_ttl}
end
```

Create `apps/write_api/lib/write_api/shortener.ex`:

```elixir
defmodule WriteApi.Shortener do
  @moduledoc """
  Creates short links.

  The write is two steps (ADR 0004): claim the code with no TTL, then store the destination
  with a TTL. A crash between the steps leaves a claimed code with no destination; it returns
  410 and is never reused.
  """

  alias ShortenerCore.{Cache, KeySource, Url, UrlStore}
  alias WriteApi.LinkParams

  @type link :: %{code: String.t(), short_url: String.t(), expires_at: DateTime.t()}
  @type error :: LinkParams.error() | :alias_taken | :unavailable

  @spec create(map(), DateTime.t()) :: {:ok, link()} | {:error, error()}
  def create(params, now \\ DateTime.utc_now()) do
    with {:ok, %{url: url, custom_alias: custom_alias, ttl_seconds: ttl}} <-
           LinkParams.parse(params) do
      expires_at = DateTime.add(now, ttl, :second)

      case custom_alias do
        nil -> create_generated(url, ttl, now, expires_at)
        custom_alias -> create_custom(custom_alias, url, ttl, now, expires_at)
      end
    end
  end

  defp create_custom(code, url, ttl, now, expires_at) do
    case claim(code, true, now, expires_at) do
      :ok -> finish(code, url, ttl, expires_at)
      {:error, :taken} -> {:error, :alias_taken}
      {:error, :unavailable} -> {:error, :unavailable}
    end
  end

  # A generated key can clash with a custom alias (ADR 0001): discard it and take the next one.
  defp create_generated(url, ttl, now, expires_at, attempt \\ 1) do
    with {:ok, code} <- KeySource.next_key() do
      case claim(code, false, now, expires_at) do
        :ok ->
          finish(code, url, ttl, expires_at)

        {:error, :taken} ->
          if attempt < max_key_attempts() do
            create_generated(url, ttl, now, expires_at, attempt + 1)
          else
            {:error, :unavailable}
          end

        {:error, :unavailable} ->
          {:error, :unavailable}
      end
    end
  end

  defp claim(code, is_custom_alias, now, expires_at) do
    UrlStore.claim(%Url{
      code: code,
      owner_id: nil,
      is_custom_alias: is_custom_alias,
      created_at: now,
      expires_at: expires_at
    })
  end

  defp finish(code, url, ttl, expires_at) do
    case UrlStore.put_destination(code, url, ttl) do
      :ok ->
        # Drop any negative entry cached before this code existed (ADR 0003). A cache error is
        # not fatal: the negative TTL is short.
        _ = Cache.delete(code)
        {:ok, %{code: code, short_url: base_url() <> "/" <> code, expires_at: expires_at}}

      {:error, :unavailable} ->
        {:error, :unavailable}
    end
  end

  defp max_key_attempts, do: Application.fetch_env!(:write_api, :max_key_attempts)
  defp base_url, do: Application.fetch_env!(:write_api, :base_url)
end
```

- [ ] **Step 5: Implement the HTTP layer**

Create `apps/write_api/lib/write_api/application.ex`:

```elixir
defmodule WriteApi.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([WriteApi.Endpoint], strategy: :one_for_one, name: WriteApi.Supervisor)
  end
end
```

Create `apps/write_api/lib/write_api/endpoint.ex`:

```elixir
defmodule WriteApi.Endpoint do
  use Phoenix.Endpoint, otp_app: :write_api

  plug Plug.RequestId
  plug Plug.Logger

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason,
    length: 16_384

  plug WriteApi.Router
end
```

Create `apps/write_api/lib/write_api/router.ex`:

```elixir
defmodule WriteApi.Router do
  use Phoenix.Router

  get "/health", WriteApi.HealthController, :show
  post "/urls", WriteApi.UrlController, :create
end
```

Create `apps/write_api/lib/write_api/error_json.ex`:

```elixir
defmodule WriteApi.ErrorJSON do
  @moduledoc "JSON bodies for errors raised before a controller runs (bad JSON, 404, 415...)."

  def render(template, _assigns) do
    %{error: Phoenix.Controller.status_message_from_template(template)}
  end
end
```

Create `apps/write_api/lib/write_api/controllers/health_controller.ex`:

```elixir
defmodule WriteApi.HealthController do
  use Phoenix.Controller, formats: [:json]

  def show(conn, _params), do: json(conn, %{status: "ok"})
end
```

Create `apps/write_api/lib/write_api/controllers/url_controller.ex`:

```elixir
defmodule WriteApi.UrlController do
  use Phoenix.Controller, formats: [:json]

  alias WriteApi.Shortener

  def create(conn, params) do
    case Shortener.create(params) do
      {:ok, link} ->
        conn |> put_status(:created) |> json(link)

      {:error, :alias_taken} ->
        error(conn, :conflict, "alias_taken")

      {:error, reason} when reason in [:invalid_url, :invalid_alias, :invalid_ttl] ->
        error(conn, :unprocessable_entity, Atom.to_string(reason))

      {:error, :unavailable} ->
        error(conn, :service_unavailable, "unavailable")
    end
  end

  defp error(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})
end
```

- [ ] **Step 6: Run them to see them pass**

Run: `cd apps/write_api && mix test`
Expected: `39 tests, 0 failures`. The `warning: ... :redirect_api ... not available` is expected until Task 8.

- [ ] **Step 7: Commit**

```bash
git add apps/write_api mix.lock
git commit -m "Add write_api: POST /urls with custom aliases, validation and two-step write"
```

---

### Task 8: redirect_api (`GET /{code}`)

**Files:**
- Create: `apps/redirect_api/mix.exs`, `apps/redirect_api/.formatter.exs`, `apps/redirect_api/test/test_helper.exs`
- Create: `apps/redirect_api/lib/redirect_api/{application,endpoint,router,error_json,resolver}.ex`, `apps/redirect_api/lib/redirect_api/controllers/{redirect_controller,health_controller}.ex`
- Test: `apps/redirect_api/test/redirect_api/redirect_controller_test.exs`

**Interfaces:**
- Consumes: `ShortenerCore.Cache.{get,put}/…`, `ShortenerCore.UrlStore.fetch/1`, `%ShortenerCore.Url{}`, config keys `cache_ttl` and `negative_cache_ttl`.
- Produces: `GET /{code}`: 302 + `Location`, 404, 410, 503, all with `Cache-Control: no-store`. `GET /health`. `RedirectApi.Resolver.resolve(code, now)` returns `{:redirect, url} | :not_found | :gone | :unavailable`. Port 4002.

- [ ] **Step 1: Create the app skeleton**

Create `apps/redirect_api/mix.exs`:

```elixir
defmodule RedirectApi.MixProject do
  use Mix.Project

  def project do
    [
      app: :redirect_api,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {RedirectApi.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:shortener_core, in_umbrella: true},
      {:phoenix, "~> 1.7"},
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.4"}
    ]
  end
end
```

Create `apps/redirect_api/.formatter.exs`:

```elixir
[
  import_deps: [:phoenix],
  inputs: ["*.{ex,exs}", "{config,lib,test}/**/*.{ex,exs}"]
]
```

Create `apps/redirect_api/test/test_helper.exs`:

```elixir
ExUnit.start()
```

Run: `mix deps.get`
Expected: no new packages; `==> redirect_api` is listed.

- [ ] **Step 2: Write the tests**

The test module defines its own `DownStore` and `DownCache` doubles and a `swap_env/2` helper that restores the config after each test.

Create `apps/redirect_api/test/redirect_api/redirect_controller_test.exs`:

```elixir
defmodule RedirectApi.RedirectControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ShortenerCore.{Cache, Url, UrlStore}

  @endpoint RedirectApi.Endpoint

  defmodule DownStore do
    @behaviour ShortenerCore.UrlStore
    @impl true
    def claim(_), do: {:error, :unavailable}
    @impl true
    def put_destination(_, _, _), do: {:error, :unavailable}
    @impl true
    def fetch(_), do: {:error, :unavailable}
  end

  defmodule DownCache do
    @behaviour ShortenerCore.Cache
    @impl true
    def get(_), do: {:error, :unavailable}
    @impl true
    def put(_, _, _), do: {:error, :unavailable}
    @impl true
    def delete(_), do: {:error, :unavailable}
  end

  setup do
    start_supervised!(UrlStore.Memory)
    start_supervised!(Cache.Memory)
    :ok
  end

  defp swap_env(key, value) do
    old = Application.fetch_env!(:shortener_core, key)
    Application.put_env(:shortener_core, key, value)
    on_exit(fn -> Application.put_env(:shortener_core, key, old) end)
  end

  defp create_link(code, long_url, ttl \\ 3_600) do
    now = DateTime.utc_now()

    :ok =
      UrlStore.claim(%Url{
        code: code,
        owner_id: nil,
        is_custom_alias: false,
        created_at: now,
        expires_at: DateTime.add(now, ttl, :second)
      })

    :ok = UrlStore.put_destination(code, long_url, ttl)
  end

  defp no_store?(conn), do: get_resp_header(conn, "cache-control") == ["no-store"]

  describe "GET /:code for a live link" do
    test "returns 302 with the Location and no-store" do
      create_link("abc1234", "https://example.com/target?x=1")

      conn = get(build_conn(), "/abc1234")

      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["https://example.com/target?x=1"]
      assert no_store?(conn)
    end

    test "fills the cache, and a cached link redirects even if the store has lost it" do
      create_link("abc1234", "https://example.com/target")
      assert get(build_conn(), "/abc1234").status == 302
      assert Cache.get("abc1234") == {:ok, {:url, "https://example.com/target"}}

      swap_env(:url_store, DownStore)
      assert get(build_conn(), "/abc1234").status == 302
    end

    test "caps the cache TTL at the link's remaining TTL" do
      create_link("short01", "https://example.com", 10)
      get(build_conn(), "/short01")
      assert Cache.Memory.ttl("short01") in 9..10
    end

    test "caps the cache TTL at the configured maximum" do
      create_link("long001", "https://example.com", 315_360_000)
      get(build_conn(), "/long001")
      assert Cache.Memory.ttl("long001") == Application.fetch_env!(:shortener_core, :cache_ttl)
    end

    test "answers HEAD like GET without a body" do
      create_link("abc1234", "https://example.com")
      conn = head(build_conn(), "/abc1234")
      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["https://example.com"]
    end

    test "serves from the store when Redis is down" do
      create_link("abc1234", "https://example.com")
      swap_env(:cache, DownCache)
      assert get(build_conn(), "/abc1234").status == 302
    end
  end

  describe "GET /:code for an unknown code" do
    test "returns 404 with no-store and caches the miss" do
      conn = get(build_conn(), "/nothere")

      assert json_response(conn, 404) == %{"error" => "not_found"}
      assert no_store?(conn)
      assert Cache.get("nothere") == {:ok, :not_found}

      assert Cache.Memory.ttl("nothere") ==
               Application.fetch_env!(:shortener_core, :negative_cache_ttl)
    end

    for code <- ["a.b", "bad%20code", String.duplicate("a", 33), "%E2%82%AC"] do
      test "returns 404 without touching the stores for #{inspect(code)}" do
        swap_env(:url_store, DownStore)
        conn = get(build_conn(), "/" <> unquote(code))
        assert json_response(conn, 404)
        assert no_store?(conn)
      end
    end
  end

  describe "GET /:code for an expired link (ADR 0004)" do
    test "returns 410 with no-store and caches it as gone" do
      create_link("old0001", "https://example.com", 1)
      Process.sleep(1_200)

      conn = get(build_conn(), "/old0001")

      assert json_response(conn, 410) == %{"error" => "gone"}
      assert no_store?(conn)
      assert Cache.get("old0001") == {:ok, :gone}
    end

    test "a claimed code with no destination (crash between the write steps) returns 410" do
      now = DateTime.utc_now()

      :ok =
        UrlStore.claim(%Url{
          code: "burned1",
          owner_id: nil,
          is_custom_alias: false,
          created_at: now,
          expires_at: DateTime.add(now, 3_600)
        })

      assert json_response(get(build_conn(), "/burned1"), 410)
    end
  end

  describe "when Cassandra is down (ADR 0003)" do
    test "a cache miss returns 503 with no-store and caches nothing" do
      swap_env(:url_store, DownStore)

      conn = get(build_conn(), "/abc1234")

      assert json_response(conn, 503) == %{"error" => "unavailable"}
      assert no_store?(conn)
      assert Cache.get("abc1234") == :miss
    end

    test "a cache hit still redirects" do
      :ok = Cache.put("hit0001", {:url, "https://example.com"}, 60)
      swap_env(:url_store, DownStore)
      assert get(build_conn(), "/hit0001").status == 302
    end
  end

  test "GET /health returns ok and is not treated as a code" do
    assert %{"status" => "ok"} = build_conn() |> get("/health") |> json_response(200)
  end
end
```

- [ ] **Step 3: Run them to see them fail**

Run: `cd apps/redirect_api && mix test`
Expected: FAIL. Every test errors because `RedirectApi.Endpoint` is undefined.

- [ ] **Step 4: Implement the resolver**

Create `apps/redirect_api/lib/redirect_api/resolver.ex`:

```elixir
defmodule RedirectApi.Resolver do
  @moduledoc """
  Cache-aside lookup of a short code.

    1. Redis. A hit answers immediately; a Redis error falls through to Cassandra.
    2. On a miss, Cassandra at QUORUM (ADR 0003), then fill the cache. The destination's cache
       TTL never exceeds the link's remaining TTL (ADR 0004).

  A Cassandra error is `:unavailable` and is never cached, so an outage is not reported (or
  remembered) as "not found" (ADR 0003).
  """

  alias ShortenerCore.{Cache, Url, UrlStore}

  @code_format ~r/\A[0-9A-Za-z_-]{1,32}\z/

  @type result :: {:redirect, String.t()} | :not_found | :gone | :unavailable

  @spec resolve(String.t(), DateTime.t()) :: result()
  def resolve(code, now \\ DateTime.utc_now()) do
    # Codes longer than any we issue, or with other characters, cannot exist: skip the stores.
    if Regex.match?(@code_format, code) do
      case Cache.get(code) do
        {:ok, {:url, url}} -> {:redirect, url}
        {:ok, :not_found} -> :not_found
        {:ok, :gone} -> :gone
        :miss -> from_store(code, now)
        {:error, :unavailable} -> from_store(code, now)
      end
    else
      :not_found
    end
  end

  defp from_store(code, now) do
    case UrlStore.fetch(code) do
      {:ok, %Url{long_url: url, expires_at: expires_at}} when is_binary(url) ->
        _ = Cache.put(code, {:url, url}, destination_ttl(expires_at, now))
        {:redirect, url}

      {:ok, %Url{}} ->
        _ = Cache.put(code, :gone, negative_ttl())
        :gone

      :not_found ->
        _ = Cache.put(code, :not_found, negative_ttl())
        :not_found

      {:error, :unavailable} ->
        :unavailable
    end
  end

  defp destination_ttl(expires_at, now) do
    remaining = DateTime.diff(expires_at, now, :second)
    remaining |> min(Application.fetch_env!(:shortener_core, :cache_ttl)) |> max(1)
  end

  defp negative_ttl, do: Application.fetch_env!(:shortener_core, :negative_cache_ttl)
end
```

- [ ] **Step 5: Implement the HTTP layer**

`Plug.Head` in the endpoint is required: without it Phoenix returns 404 for `HEAD` on a `GET` route.

Create `apps/redirect_api/lib/redirect_api/application.ex`:

```elixir
defmodule RedirectApi.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([RedirectApi.Endpoint],
      strategy: :one_for_one,
      name: RedirectApi.Supervisor
    )
  end
end
```

Create `apps/redirect_api/lib/redirect_api/endpoint.ex`:

```elixir
defmodule RedirectApi.Endpoint do
  use Phoenix.Endpoint, otp_app: :redirect_api

  plug Plug.RequestId
  plug Plug.Logger
  plug Plug.Head

  plug RedirectApi.Router
end
```

Create `apps/redirect_api/lib/redirect_api/router.ex`. `/health` must stay above `/:code`.

```elixir
defmodule RedirectApi.Router do
  use Phoenix.Router

  get "/health", RedirectApi.HealthController, :show
  get "/:code", RedirectApi.RedirectController, :show
end
```

Create `apps/redirect_api/lib/redirect_api/error_json.ex`:

```elixir
defmodule RedirectApi.ErrorJSON do
  @moduledoc "JSON bodies for errors raised before a controller runs (bad JSON, 404, 415...)."

  def render(template, _assigns) do
    %{error: Phoenix.Controller.status_message_from_template(template)}
  end
end
```

Create `apps/redirect_api/lib/redirect_api/controllers/health_controller.ex`:

```elixir
defmodule RedirectApi.HealthController do
  use Phoenix.Controller, formats: [:json]

  def show(conn, _params), do: json(conn, %{status: "ok"})
end
```

Create `apps/redirect_api/lib/redirect_api/controllers/redirect_controller.ex`:

```elixir
defmodule RedirectApi.RedirectController do
  use Phoenix.Controller, formats: [:json]

  alias RedirectApi.Resolver

  # ADR 0006: 302 with no-store so every click reaches this service (and is counted, ADR 0005)
  # and an expired link stops working immediately. The same header goes on 404, 410 and 503.
  def show(conn, %{"code" => code}) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case Resolver.resolve(code) do
      {:redirect, url} ->
        conn |> put_resp_header("location", url) |> send_resp(302, "")

      :gone ->
        conn |> put_status(:gone) |> json(%{error: "gone"})

      :not_found ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      :unavailable ->
        conn |> put_status(:service_unavailable) |> json(%{error: "unavailable"})
    end
  end
end
```

- [ ] **Step 6: Run them to see them pass**

Run: `cd apps/redirect_api && mix test`
Expected: `16 tests, 0 failures` (the expiry test takes about 1.2 seconds). The "not available" warnings from Task 1 are gone.

Run: `mix test` from the repo root.
Expected: `33 tests, 0 failures, 14 excluded` (shortener_core), `16 tests, 0 failures` (redirect_api), `39 tests, 0 failures` (write_api).

- [ ] **Step 7: Commit**

```bash
git add apps/redirect_api mix.lock
git commit -m "Add redirect_api: cache-aside GET /{code} with 302, 404, 410 and 503"
```

---

### Task 9: Containers, smoke test, README and end-to-end verification

**Files:**
- Create: `Dockerfile`, `.dockerignore`, `scripts/smoke.sh`, `README.md`
- Modify: `docker-compose.yml` (add `migrate`, `write-api`, `redirect-api`)

**Interfaces:**
- Consumes: `mix shortener.cassandra.setup` (Task 5), both apps' endpoints (Tasks 7, 8), the environment variables read in `config/runtime.exs`.
- Produces: `docker compose up -d --build` starts the whole milestone-1 system. `scripts/smoke.sh` is the end-to-end check reused by later milestones.

- [ ] **Step 1: Create the image**

The image compiles the whole umbrella in `prod`; each service runs `mix run --no-halt` from its own app directory, which starts only that app and `shortener_core`.

Create `Dockerfile`:

```dockerfile
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
```

Create `.dockerignore`:

```text
_build
deps
.git
.elixir_ls
```

- [ ] **Step 2: Add the services to Compose**

Replace the whole of `docker-compose.yml` with the following (the `cassandra` and `redis` services are unchanged). `migrate` is a one-shot job that creates the schema; the APIs wait for it to finish successfully.

```yaml
# Milestone 1 stack: Cassandra, Redis, write_api, redirect_api.
# Cassandra runs one node with RF=1 locally; production uses RF=3 (ADR 0003).
services:
  cassandra:
    image: cassandra:5
    environment:
      MAX_HEAP_SIZE: 512M
      HEAP_NEWSIZE: 128M
    ports:
      - "127.0.0.1:9042:9042"
    healthcheck:
      test: ["CMD-SHELL", "cqlsh -e 'describe keyspaces' >/dev/null 2>&1"]
      interval: 10s
      timeout: 10s
      retries: 30
      start_period: 30s

  redis:
    image: redis:7
    command: ["redis-server", "--maxmemory", "256mb", "--maxmemory-policy", "allkeys-lru"]
    ports:
      - "127.0.0.1:6379:6379"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 10

  # One-shot job: creates the keyspace and tables, then exits.
  migrate:
    build: .
    working_dir: /app/apps/shortener_core
    command: ["mix", "shortener.cassandra.setup"]
    environment:
      CASSANDRA_NODES: cassandra:9042
      CASSANDRA_REPLICATION_FACTOR: "1"
    depends_on:
      cassandra:
        condition: service_healthy
    restart: "no"

  write-api:
    build: .
    working_dir: /app/apps/write_api
    command: ["mix", "run", "--no-halt"]
    environment: &service_env
      CASSANDRA_NODES: cassandra:9042
      REDIS_URL: redis://redis:6379
      BASE_URL: http://localhost:4002
    ports:
      - "127.0.0.1:4001:4001"
    depends_on: &service_deps
      migrate:
        condition: service_completed_successfully
      redis:
        condition: service_healthy

  redirect-api:
    build: .
    working_dir: /app/apps/redirect_api
    command: ["mix", "run", "--no-halt"]
    environment: *service_env
    ports:
      - "127.0.0.1:4002:4002"
    depends_on: *service_deps
```

- [ ] **Step 3: Create the smoke test**

Create `scripts/smoke.sh`, then run `chmod +x scripts/smoke.sh`:

```bash
#!/usr/bin/env bash
# End-to-end smoke test: create a link, follow it, check the headers and the error cases.
# Needs the stack running (docker compose up -d) and curl + jq installed.
set -euo pipefail

WRITE_API="${WRITE_API_URL:-http://localhost:4001}"
REDIRECT_API="${REDIRECT_API_URL:-http://localhost:4002}"

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "waiting for services..."
for i in $(seq 1 60); do
  curl -sf "$WRITE_API/health" >/dev/null && curl -sf "$REDIRECT_API/health" >/dev/null && break
  [ "$i" -eq 60 ] && fail "services did not become healthy"
  sleep 2
done

echo "creating a link..."
body=$(curl -sf -X POST "$WRITE_API/urls" -H 'content-type: application/json' \
  -d '{"url":"https://example.com/smoke"}') || fail "POST /urls failed"
code=$(echo "$body" | jq -r .code)
[[ "$code" =~ ^[0-9A-Za-z]{7}$ ]] || fail "unexpected code: $code"

echo "following /$code..."
headers=$(curl -s -o /dev/null -D - "$REDIRECT_API/$code")
echo "$headers" | head -1 | grep -q ' 302' || fail "expected 302, got: $(echo "$headers" | head -1)"
echo "$headers" | grep -qi '^location: https://example.com/smoke' || fail "wrong Location"
echo "$headers" | grep -qi '^cache-control: no-store' || fail "missing Cache-Control: no-store"

echo "custom alias, then a clash..."
alias_name="smoke-$(date +%s)"
curl -sf -X POST "$WRITE_API/urls" -H 'content-type: application/json' \
  -d "{\"url\":\"https://example.com/a\",\"custom_alias\":\"$alias_name\"}" >/dev/null || fail "alias create failed"
status=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$WRITE_API/urls" -H 'content-type: application/json' \
  -d "{\"url\":\"https://example.com/b\",\"custom_alias\":\"$alias_name\"}")
[ "$status" = "409" ] || fail "expected 409 for a taken alias, got $status"

echo "unknown code..."
status=$(curl -s -o /dev/null -w '%{http_code}' "$REDIRECT_API/doesnotexist")
[ "$status" = "404" ] || fail "expected 404, got $status"

echo "expired link..."
curl -sf -X POST "$WRITE_API/urls" -H 'content-type: application/json' \
  -d '{"url":"https://example.com/short","custom_alias":"short-'"$alias_name"'","ttl_seconds":1}' >/dev/null || fail "short ttl create failed"
sleep 2
status=$(curl -s -o /dev/null -w '%{http_code}' "$REDIRECT_API/short-$alias_name")
[ "$status" = "410" ] || fail "expected 410 for an expired link, got $status"

echo "OK"
```

- [ ] **Step 4: Create the README**

Create `README.md`:

````markdown
# URL Shortener

An Elixir/Phoenix URL shortener built to the design in
[docs/superpowers/specs/2026-10-07-url-shortener-design.md](docs/superpowers/specs/2026-10-07-url-shortener-design.md).
Architecture decisions are recorded in [docs/adr/](docs/adr/README.md).

This README covers milestone 1 (the core path). The architecture write-up comes with milestone 6.

## Run it

Prerequisites: Docker with Compose v2, plus `curl` and `jq` for the smoke test.

```bash
docker compose up -d --build   # Cassandra, Redis, schema setup, write-api, redirect-api
./scripts/smoke.sh             # create a link, follow it, check the error cases
```

| Service | URL | Purpose |
|---|---|---|
| write-api | http://localhost:4001 | `POST /urls`, `GET /health` |
| redirect-api | http://localhost:4002 | `GET /{code}`, `GET /health` |

Create a link:

```bash
curl -X POST http://localhost:4001/urls \
  -H 'content-type: application/json' \
  -d '{"url": "https://example.com/some/long/path", "custom_alias": "my-link", "ttl_seconds": 3600}'
```

`custom_alias` and `ttl_seconds` are optional. The default (and maximum) lifetime is 10 years.

| Status | Meaning |
|---|---|
| 201 | Created |
| 409 | The custom alias is taken |
| 422 | Invalid `url`, `custom_alias` or `ttl_seconds` |
| 503 | Cassandra is unavailable, or no free generated key was found |

`GET /{code}` answers 302 with `Cache-Control: no-store` (ADR 0006), 404 for an unknown code, 410 for an
expired link, and 503 when Cassandra cannot be reached.

## Develop

Toolchain: `asdf install` reads `.tool-versions` (Erlang 27.0, Elixir 1.18.0-otp-27).

```bash
mix deps.get
mix test                                       # unit tests, no Docker needed
docker compose up -d --wait cassandra redis
INTEGRATION=1 mix test                         # also runs the tests tagged :integration
mix format --check-formatted
```
````

- [ ] **Step 5: Build and start the stack**

Run: `docker compose up -d --build`
Expected: the image builds (about 3 minutes the first time), and `docker compose ps -a` shows `cassandra` and `redis` healthy, `migrate` `Exited (0)`, and `write-api` and `redirect-api` running.

Run: `docker compose logs migrate`
Expected: the last line is `Cassandra schema is ready.` (earlier lines may say `Cassandra not ready ... retrying` if the node was still starting).

- [ ] **Step 6: Run the smoke test**

Run: `./scripts/smoke.sh`
Expected output ends with:

```
creating a link...
following /<7 characters>...
custom alias, then a clash...
unknown code...
expired link...
OK
```

- [ ] **Step 7: Check the two failure modes from spec §10 by hand**

Create a link and keep its code: `code=$(curl -s -X POST localhost:4001/urls -H 'content-type: application/json' -d '{"url":"https://example.com/drill"}' | jq -r .code)`, then `curl -s -o /dev/null -w '%{http_code}\n' localhost:4002/$code` (expect `302`, which also warms the cache).

Redis down: run `docker compose stop redis`, then:

- `curl -s -o /dev/null -w '%{http_code}\n' localhost:4002/$code` expects `302` (served from Cassandra).
- `curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:4001/urls -H 'content-type: application/json' -d '{"url":"https://example.com/x"}'` expects `201`.

Run `docker compose start redis` and wait a few seconds. Cassandra down: run `docker compose stop cassandra`, then:

- the same redirect request expects `302` (cache hit).
- `curl -s -o /dev/null -w '%{http_code}\n' localhost:4002/neverseen1` expects `503`, not `404`.
- the same `POST /urls` expects `503`.

Run `docker compose start cassandra`.

- [ ] **Step 8: Run the full verification**

Run: `mix format --check-formatted`
Expected: no output, exit code 0.

Run: `mix test`
Expected: `33 tests, 0 failures, 14 excluded`, `16 tests, 0 failures`, `39 tests, 0 failures`.

Run: `INTEGRATION=1 mix test`
Expected: `33 tests, 0 failures`, `16 tests, 0 failures`, `39 tests, 0 failures` (needs Cassandra and Redis from Compose to be running).

Run: `grep -rn "USING TTL" apps/*/lib | grep -i "insert"`
Expected: no output (ADR 0004: no `INSERT ... USING TTL` on `urls`).

Run: `grep -rnE "consistency:" apps/*/lib | grep -v "serial_consistency\|default_consistency"`
Expected: no output (ADR 0003: no per-call consistency override).

- [ ] **Step 9: Stop the stack and commit**

```bash
docker compose down
git add Dockerfile .dockerignore docker-compose.yml scripts README.md
git commit -m "Add containers, smoke test and README for milestone 1"
```

---

## Self-Review

**Spec coverage (milestone 1 of §13: "write, redirect, cache, Cassandra, Compose, test scaffolding, `KeySource` with the in-process generator"):**

| Requirement | Task |
|---|---|
| `POST /urls`, custom alias, 409, no deduplication, 201 (§4) | 7 |
| `GET /{code}`, Redis cache-aside, 404 and negative cache, cache TTL capped by remaining TTL (§5) | 6, 8 |
| Cassandra `urls` table, two-step write, TTL on the destination, QUORUM (§3, ADR 0003, ADR 0004) | 4, 5, 7 |
| `KeySource` behaviour and in-process generator (§2) | 3 |
| Base62 (§2) | 2 |
| Failure behaviour for Cassandra and Redis down (§10) | 6, 7, 8, 9 (hand drill) |
| 302 with `no-store`, 410 for expired (ADR 0006, ADR 0004) | 8 |
| Generated-key clash with a custom alias (ADR 0001) | 7 |
| `/health` on every service, request ID in logs (§11) | 7, 8 (`Plug.RequestId`, `Plug.Logger`, `config :logger` metadata) |
| Test scaffolding: unit tests without Docker, `:integration` tag, contract tests (§12) | 1, 3, 4, 5, 6 |
| `docker compose up` (§1) and an end-to-end smoke script (§12) | 9 |

**Not covered here, on purpose:** Prometheus metrics and the cache-hit-ratio telemetry from §11 (M6), the second load balancer and k6 results (M6), the `edge` app and rate limiting (M3), click events (M4), URL safety checks (M5). The only §11 items in this milestone are `/health` and request IDs.

**Choices made in this plan that the spec and ADRs do not state** (change them in `config/*.exs` or `LinkParams` if you disagree): request field names `custom_alias` and `ttl_seconds`; alias rules (3 to 32 characters of `[0-9A-Za-z_-]`, reserved words `health`, `urls`, `stats`); URL rules (http or https, a host, no whitespace or control characters, at most 2,048 bytes); the cache cap of 3,600 s for destinations and 30 s for negative entries; ports 4001 (write) and 4002 (redirect) with no load balancer in front yet; `BASE_URL` pointing at the redirect service; "3 clashes in a row" read as 3 attempts in total.

**Placeholder scan:** none. Every file is shown in full and every command has its expected output.

**Type consistency:** `UrlStore.claim/1` takes `%Url{}`; `put_destination/3` takes `(code, long_url, ttl_seconds)`; `fetch/1` returns `{:ok, %Url{}}`, `:not_found` or `{:error, :unavailable}` in the behaviour, both implementations and both services. `Cache.get/1` returns `{:ok, entry} | :miss | {:error, :unavailable}` with `entry` one of `{:url, String.t}`, `:not_found`, `:gone` everywhere. `KeySource.next_key/0` returns `{:ok, code} | {:error, :unavailable}` in the behaviour, the in-process source and the scripted double.
