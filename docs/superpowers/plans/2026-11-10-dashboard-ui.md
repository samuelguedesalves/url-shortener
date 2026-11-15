# Dashboard UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A signed-in user opens `/dashboard`, sees their links in a compact list, and creates a link (custom alias or generated code) from a modal; sign-in is Google, driven by environment variables.

**Architecture:** A Phoenix LiveView (`WriteApi.DashboardLive`) inside the `write_api` app at `/dashboard`, same endpoint and port (4001). It calls `WriteApi.Links` and `WriteApi.Shortener` directly, not the JSON API. Identity is the existing signed `session` cookie; its raw token is passed to the LiveView and re-verified on every mount and every write event. Sign-in and sign-out use `fetch` against the existing `POST /auth/google` and `POST /auth/logout`.

**Tech Stack:** Elixir 1.18, Phoenix 1.8.15, `phoenix_live_view ~> 1.2`, `phoenix_html ~> 4.4`, `esbuild ~> 0.10`, `tailwind ~> 0.5` (Tailwind v4), daisyUI 5 (vendored), Google Identity Services script. ExUnit with `Phoenix.LiveViewTest`.

**Spec:** `docs/superpowers/specs/2026-11-10-dashboard-ui-design.md` (builds on `docs/superpowers/specs/2026-11-09-dashboard-api-requirements.md`, already implemented).

## Global Constraints

- `redirect_api` is not modified: no file under `apps/redirect_api/lib` or `config` entries for `:redirect_api` change.
- The JSON API stays as it is: `POST /urls` still returns exactly `{code, short_url, expires_at, is_custom_alias}`; `scripts/smoke.sh` and the existing tests pass unchanged.
- UI text is Portuguese (pt-BR), as in the mockups: "Meus links", "+ Novo link", "Gerar automaticamente", "Escolher alias", "Esse alias já está em uso", "Carregar mais", "destino removido", "expirado", "alias", "gerado". Strings live in the components module, not scattered.
- The ID token is never stored or logged; the page only forwards it to `POST /auth/google`.
- `mix test` needs no Docker or network: in-memory stores and `WriteApi.Doubles.FakeVerifier`. Run from the repo root: `mix test`, `mix format --check-formatted`, `mix compile --warnings-as-errors --force` (in `apps/write_api`).
- Commit trailer on every commit: `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. Work on branch `feat/visual-dashboard`; no worktree.
- Compose stack runs `MIX_ENV=prod` over plain `http://localhost`, so `COOKIE_SECURE=false` there (already set).

## Review Focus

Failure modes the spec implies but does not spell out. Each has a test in the owning task:

1. The store is down while loading the list or creating a link: a visible, retryable message, never a crash (Tasks 5, 6).
2. The session cookie expires while the page stays open: the next load-more or create acts as signed out, never as the old user (Tasks 5, 6).
3. A stored destination containing HTML characters renders escaped (Task 5).
4. A double submit of the create form creates one link, not two (Task 6).
5. A user with no picture and a blank name still gets a header (Task 5).

## File Structure

New, all under `apps/write_api/` unless stated:
- `lib/write_api/dashboard_live.ex`: the LiveView (state and events).
- `lib/write_api/dashboard_components.ex`: function components and every UI string.
- `lib/write_api/dashboard/auth.ex`: `on_mount` hook, the live-session callback, `check_origin?/1`.
- `lib/write_api/layouts.ex`: root layout (`<head>`, scripts, styles).
- `assets/css/app.css`, `assets/js/app.js`, `assets/js/hooks.js`, `assets/vendor/*`: asset sources.
- `test/support/dashboard_case.ex`: shared signed-in helpers.
- `test/write_api/dashboard_*_test.exs`.
- Repo root: `.env.example`, `docs/adr/0008-*.md`.

Modified: `mix.exs`, `lib/write_api/{endpoint,router,session,shortener,config}.ex`, `lib/write_api/controllers/url_controller.ex`, `config/{config,runtime,dev}.exs`, `Dockerfile`, `docker-compose.yml`, `README.md`, `.gitignore`, ADR 0007, `docs/adr/README.md`, the API requirements doc.

---

### Task 1: Backend groundwork (creation result, session token API)

**Files:**
- Modify: `apps/write_api/lib/write_api/shortener.ex`, `apps/write_api/lib/write_api/session.ex`, `apps/write_api/lib/write_api/controllers/url_controller.ex`
- Test: `apps/write_api/test/write_api/shortener_test.exs`, `session_test.exs`, `url_controller_test.exs`

**Interfaces:**
- Produces: `WriteApi.Shortener.create/2` result map gains `created_at: DateTime.t()` (the ms-truncated `now`).
- Produces: `WriteApi.Session.token(Plug.Conn.t()) :: {:ok, String.t()} | :none` (the raw `session` cookie value, no verification); `WriteApi.Session.verify_token(String.t(), DateTime.t()) :: {:ok, String.t()} | :none` (user id; `:none` for tampered, expired, wrong secret, issued in the future). `Session.user_id/2` keeps its signature and is rebuilt on these two.

- [ ] **Step 1: Write the failing tests**
  - `shortener_test.exs`: `"returns created_at, truncated to milliseconds"`: with `now: ~U[2026-11-10 12:00:00.123456Z]`, `{:ok, link}` has `link.created_at == ~U[2026-11-10 12:00:00.123Z]`.
  - `url_controller_test.exs`: `"POST /urls responds with exactly code, short_url, expires_at, is_custom_alias"`: `body |> Map.keys() |> Enum.sort() == ["code", "expires_at", "is_custom_alias", "short_url"]`.
  - `session_test.exs`: `"verify_token/2 accepts a token the cookie carries and rejects expired and tampered ones"`, and `"token/1 is :none without a cookie"`.
- [ ] **Step 2: Run them to verify they fail.** `mix test apps/write_api/test/write_api/shortener_test.exs apps/write_api/test/write_api/session_test.exs apps/write_api/test/write_api/url_controller_test.exs` fails on the new tests only.
- [ ] **Step 3: Implement** the new return field in `Shortener.finish/5` (thread `link.now` through), `UrlController.create` replying with `Map.delete(link, :created_at)`, and the two `Session` functions (keep the existing live?/secret checks in one place).
- [ ] **Step 4: Run the full `mix test`.** Expected: 0 failures.
- [ ] **Step 5: Commit** `feat(write_api): expose created_at on creation and verify session tokens directly`.

---

### Task 2: Config, secrets, origin and compose

**Files:**
- Modify: `apps/write_api/lib/write_api/config.ex`, `config/runtime.exs`, `docker-compose.yml`
- Test: `apps/write_api/test/write_api/config_test.exs`

**Interfaces:**
- Produces: `WriteApi.Config.google_client_id() :: String.t() | nil` (nil when unset or blank after trim).
- Changes: `Config.validate!/0` (only when `:require_secrets`) also raises unless `WriteApi.Endpoint`'s `:secret_key_base` is a binary of at least 64 bytes.
- Changes: in `runtime.exs`, write_api's `secret_key_base` is `System.get_env("SECRET_KEY_BASE")` in `:prod` (so a missing value fails the boot check) and the current 64×`"a"` placeholder in other envs. The `:redirect_api` entry is untouched. `dashboard_origin` defaults to `"http://localhost:#{WRITE_API_PORT}"` when `DASHBOARD_ORIGIN` is unset. `DASHBOARD_ORIGIN` now means "the public origin this service is served from".

- [ ] **Step 1: Write the failing tests** in `config_test.exs`: `google_client_id/0` returns nil for unset, `""` and `"   "`, and the trimmed value otherwise; `validate!/0` raises with `require_secrets: true` and a `secret_key_base` of 63 bytes or nil, and passes with a 64-byte one and a valid session secret (use `Doubles.swap_env`).
- [ ] **Step 2: Run to verify they fail** (`mix test apps/write_api/test/write_api/config_test.exs`).
- [ ] **Step 3: Implement** in `config.ex` and `runtime.exs` as described above.
- [ ] **Step 4: Compose.** Under `write-api` only: `SECRET_KEY_BASE` (a dev-only 64+ byte value, commented as such) and `DASHBOARD_ORIGIN: http://localhost:4001` (replacing the 5173 value). Update the comment on `DASHBOARD_ORIGIN` accordingly.
- [ ] **Step 5: Run `mix test`, then verify the stack boots.** `docker compose up -d --build`, then `docker compose logs write-api --tail 20` shows no boot error and `bash scripts/smoke.sh` prints OK. (If the LAN override is in use, add `-f docker-compose.lan.yml` with `LAN_IP` set.)
- [ ] **Step 6: Commit** `feat(write_api): require a real SECRET_KEY_BASE in prod and serve the dashboard origin from the app`.

---

### Task 3: LiveView foundation and asset pipeline

**Files:**
- Create: `lib/write_api/dashboard_live.ex`, `lib/write_api/dashboard/auth.ex`, `lib/write_api/layouts.ex`, `assets/css/app.css`, `assets/js/app.js`, `assets/vendor/*`, `test/support/dashboard_case.ex`, `test/write_api/dashboard_live_test.exs`
- Modify: `apps/write_api/mix.exs`, `lib/write_api/endpoint.ex`, `lib/write_api/router.ex`, `config/config.exs`, `config/dev.exs`, `.gitignore`
- Test: `apps/write_api/test/write_api/dashboard_live_test.exs`

**Interfaces:**
- Produces: route `live "/dashboard", WriteApi.DashboardLive` inside `live_session :dashboard, on_mount: {WriteApi.Dashboard.Auth, :fetch_user}, session: {WriteApi.Dashboard.Auth, :live_session, []}`.
- Produces: `WriteApi.Dashboard.Auth.live_session(Plug.Conn.t()) :: %{String.t() => String.t() | nil}` returning `%{"session_token" => encrypted_cookie_or_nil}` (the cookie from `Session.token/1`, encrypted with `Plug.Crypto` under the endpoint `secret_key_base` and a dedicated salt, so the raw credential never reaches the page; `on_mount` decrypts, then verifies); `on_mount(:fetch_user, params, session, socket)` assigns `:session_token` and `:current_user` (a `ShortenerCore.User` or nil, via `Session.verify_token(token, DateTime.utc_now())` then `UserStore.get/1`; `{:error, :unavailable}` assigns `current_user: nil` and `auth_error: :unavailable`); `check_origin?(URI.t()) :: boolean()` true only for the configured `dashboard_origin`.
- Produces: `WriteApi.DashboardCase` (ExUnit case template, `async: false`, starts the three Memory stores) exporting `user!(id, attrs \\ %{}) :: User.t()` and `signed_in_conn(user_id, opts \\ []) :: Plug.Conn.t()` (cookie issued through `Session.issue/3`, `opts[:now]` forwarded).
- Produces: the assigns later tasks extend: `:current_user`, `:session_token`.

- [ ] **Step 1: Generate a reference project.** In the scratchpad directory run `mix phx.new scratch --no-ecto --no-mailer --no-gettext --no-dashboard` and use it only to copy: `assets/vendor/{daisyui.js,daisyui-theme.js,topbar.js}`, `assets/css/app.css` (Tailwind v4 + daisyUI plugin lines), the `esbuild`/`tailwind` blocks of `config/config.exs`, the `assets.*` aliases, and the dev watchers. Do not copy anything else.
- [ ] **Step 2: Write the failing tests** in `dashboard_live_test.exs`:
  - `"GET /dashboard renders and links the stylesheet and script"`: `conn |> get("/dashboard") |> html_response(200)` contains `/assets/app.css` and `/assets/app.js`.
  - `"a visit without a cookie mounts signed out"`: `live(conn, "/dashboard")` assigns `current_user: nil` (assert via rendered signed-out marker `data-test="signed-out"`).
  - `"a visit with a valid cookie mounts as that user"`: marker `data-test="signed-in"`.
  - `"an expired, tampered or unknown-user cookie mounts signed out"`.
  - `"a foreign Origin is refused for the websocket"`: `Dashboard.Auth.check_origin?(URI.parse("http://evil.test"))` is false, the configured origin true.
- [ ] **Step 3: Run to verify they fail.**
- [ ] **Step 4: Implement** the dependencies (`phoenix_live_view`, `phoenix_html`, `esbuild`, `tailwind`, and `phoenix_live_reload` dev-only), the endpoint (`socket "/live", Phoenix.LiveView.Socket` with `websocket: [check_origin: {WriteApi.Dashboard.Auth, :check_origin?, []}]`, `Plug.Static` for `/assets` from `:write_api`), the router (`:browser` pipeline with `fetch_live_flash`, `put_root_layout`, `put_secure_browser_headers`; the existing `/auth` and `/urls` scopes stay JSON), the root layout, and the asset aliases `assets.setup`, `assets.build`, `assets.deploy`. LiveView's own CSRF/session cookie, if Phoenix needs one, is a separate cookie used for nothing else; identity is never read from it. The LiveView renders only the two markers for now.
- [ ] **Step 5: Build the assets and run the tests.** `cd apps/write_api && mix assets.setup && mix assets.build`, then `mix test`. Expected: 0 failures; `priv/static/assets` is ignored by git (add to `.gitignore`).
- [ ] **Step 6: Commit** `feat(write_api): add the LiveView shell, session mounting and asset pipeline`.

---

### Task 4: Signed-out page and sign-in/sign-out

**Files:**
- Create: `lib/write_api/dashboard_components.ex`, `assets/js/hooks.js`, `test/write_api/dashboard_sign_in_test.exs`
- Modify: `lib/write_api/dashboard_live.ex`, `lib/write_api/layouts.ex`, `assets/js/app.js`

**Interfaces:**
- Consumes: Task 3 assigns and `Config.google_client_id/0`.
- Produces: `WriteApi.DashboardComponents.sign_in_card/1` (attrs: `client_id`, `error`); `app_header/1` (attrs: `user`); both pure function components.
- Produces: JS hooks `GoogleSignIn` (reads `data-client-id`, loads Google's `https://accounts.google.com/gsi/client`, renders the button, on credential sends `fetch("/auth/google", {method: "POST", credentials: "same-origin", JSON body {credential}})`, reloads on 200, otherwise `pushEvent("sign_in_failed", {code})`, and pushes `"sign_in_failed"` with code `"script_blocked"` if the script does not load within 10 s) and `SignOut` (fetch `POST /auth/logout`, then reload).
- Produces: LiveView event `"sign_in_failed"` with `%{"code" => code}` setting `:sign_in_error`.

- [ ] **Step 1: Write the failing tests** in `dashboard_sign_in_test.exs`:
  - `"signed out with a client id renders the Google button hook configured with it"`: the HTML has `phx-hook="GoogleSignIn"` and `data-client-id="the-id.apps.googleusercontent.com"`; no link or user data appears.
  - `"signed out without a client id shows the not-configured message and no button"`.
  - `"a client id with quotes and angle brackets is escaped in the attribute"`.
  - `"sign_in_failed shows a message per code"`: `invalid_token`, `unavailable`, `forbidden_origin`, `script_blocked` each render a distinct Portuguese message; an unknown code renders a generic one.
  - `"signed in renders the header with the user's name and a sign-out control"` (marker `phx-hook="SignOut"`).
- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement** the components, the hooks, the two script/CSS touches in the layout, and the event handler. The `forbidden_origin` message tells the operator to check `DASHBOARD_ORIGIN`.
- [ ] **Step 4: Run `mix test` and `mix assets.build`.** Expected: 0 failures, no build warnings.
- [ ] **Step 5: Manual check of the signed-out screen.** With the stack up (`docker compose up -d --build`), `curl -s localhost:4001/dashboard` returns the card HTML, and opening `http://localhost:4001/dashboard` in a browser shows the styled card. (The Google button needs a real client id; without one the card says sign-in is not configured.)
- [ ] **Step 6: Commit** `feat(write_api): signed-out dashboard page with Google sign-in and sign-out hooks`.

---

### Task 5: Link list

**Files:**
- Modify: `lib/write_api/dashboard_live.ex`, `lib/write_api/dashboard_components.ex`
- Test: `apps/write_api/test/write_api/dashboard_list_test.exs`

**Interfaces:**
- Consumes: `WriteApi.Links.page(owner_id, query) :: {:ok, %{links: [map], next_cursor: String.t() | nil}} | {:error, :unavailable | ...}`; link maps have string-free atom keys `code, short_url, long_url, is_custom_alias, created_at, expires_at, status`.
- Produces: `DashboardComponents.link_row/1` (attr `link`), `link_list/1` (attrs `links` stream, `next_cursor`, `status`), `empty_state/1`, `load_error/1`. LiveView assigns `:links_status` (`:ok | :error`), `:next_cursor`, stream `:links`, `:loaded_count`. Events: `"load_more"`, `"retry"`, `"open_modal"` (button only; modal arrives in Task 6).
- Produces: a private LiveView helper `ensure_session(socket) :: {:ok, socket} | {:signed_out, socket}` that re-verifies `socket.assigns.session_token` against the current time and, when it fails, redirects to `/dashboard`. Every write or paging event calls it first (Task 6 reuses it).

- [ ] **Step 1: Write the failing tests** in `dashboard_list_test.exs`:
  - `"lists only the signed-in user's links"`: two users, each sees only their codes.
  - `"orders newest first and tags alias vs generated"`; the row shows the destination and the date.
  - `"an expired link is dimmed, tagged expirado, shows destino removido and no copy control"`.
  - `"title shows the count and a plus sign while more pages exist"`.
  - `"load_more appends the next page without duplicates or gaps"` (25 links, `limit` 20 then 5).
  - `"an empty list shows the empty state with the create call to action"`.
  - Review Focus 1: `"store down on mount shows a retryable error"`; `"retry loads the list once the store is back"` (swap `:url_store` with `Doubles.DownStore`, then back).
  - Review Focus 2: `"load_more after the cookie expired redirects to /dashboard and shows no more links"` (issue the cookie 10 s in the past, mount, then `Doubles.swap_env(:write_api, :session_ttl, 5)`, `render_click`).
  - Review Focus 3: `"a destination with HTML characters is escaped"`: a stored `long_url` of `https://example.com/?q=<script>alert(1)</script>` appears as `&lt;script&gt;` and never as a raw `<script>` tag.
  - Review Focus 5: `"a user with no picture and a blank name still renders the header"`.
- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement** the list per spec section 3.2 (two lines per link, copy button only on active links, relative or short date, "Carregar mais" button when `next_cursor` is set, page size 20). Use a LiveView stream for rows. The destination is rendered as text with `truncate`.
- [ ] **Step 4: Run `mix test`.** Expected: 0 failures.
- [ ] **Step 5: Commit** `feat(write_api): dashboard link list with paging, empty and error states`.

---

### Task 6: "Novo link" modal

**Files:**
- Modify: `lib/write_api/dashboard_live.ex`, `lib/write_api/dashboard_components.ex`, `assets/js/hooks.js`
- Test: `apps/write_api/test/write_api/dashboard_create_test.exs`

**Interfaces:**
- Consumes: `WriteApi.Shortener.create(params, owner_id: id) :: {:ok, link} | {:error, :invalid_url | :invalid_alias | :invalid_ttl | :alias_taken | :unavailable}` (link has `code, short_url, expires_at, created_at, is_custom_alias`); `ensure_session/1` from Task 5.
- Produces: `DashboardComponents.new_link_modal/1` (attrs `form`, `mode`, `errors`, `submitting`, `base_host`), `link_created/1` (attr `link`). Assigns `:modal` (`nil | :form | {:created, link}`), `:mode` (`"generate" | "alias"`), `:form`, `:form_error`. Events: `"open_modal"`, `"close_modal"`, `"set_mode"` (`%{"mode" => ...}`), `"create"` (form params `url`, `alias`, `ttl_seconds`). JS hook `Copy` (clipboard write; falls back to selecting the text when `navigator.clipboard` is unavailable; never throws).
- The `"create"` event maps to API params: `url`, `custom_alias` only when mode is `"alias"`, `ttl_seconds` only when non-blank (integer seconds). The address prefix in the modal is the host of `Application.fetch_env!(:write_api, :base_url)`.

- [ ] **Step 1: Write the failing tests** in `dashboard_create_test.exs`:
  - `"open_modal shows the form with Gerar automaticamente selected and no alias field"`; `set_mode alias` reveals the alias input.
  - `"creating with a chosen alias adds it to the top of the list tagged alias"` and the success state shows the full short link.
  - `"creating in generate mode makes a 7-character code tagged gerado, owned by the user"` (verify with `Links.page/2` and `UrlStore.fetch/1`).
  - `"a taken alias keeps the modal open with Esse alias já está em uso"`, creates nothing.
  - `"an invalid or reserved alias (for example auth) and an invalid url show their messages in the form"` (one assertion per `:invalid_alias`, `:invalid_url`, `:invalid_ttl`).
  - `"an alias typed while in generate mode is ignored"`.
  - Review Focus 1: `"store down on create keeps the modal open with an unavailable message"` (swap `:url_store` to `Doubles.DownStore`).
  - Review Focus 2: `"create after the cookie expired redirects to /dashboard and creates nothing"` (same technique as Task 5).
  - Review Focus 4: `"a second create after success creates nothing"` (submit twice; `Links.page/2` has one link; the button carries `phx-disable-with`).
  - `"close_modal returns to the list and the form resets on reopen"`.
- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement** per spec section 3.3: modal built with daisyUI's modal component, the radio-style selector, the muted preview line (a fixed example shape, not a real code), the expiry control (a select with presets: 1 hora, 1 dia, 7 dias, 30 dias, 1 ano, 10 anos (padrão), mapped to seconds; the maximum is `ShortenerCore`'s `max_link_ttl`), and the success state. After success, insert the new link at the top of the `:links` stream and increment `:loaded_count`.
- [ ] **Step 4: Run `mix test`.** Expected: 0 failures.
- [ ] **Step 5: Commit** `feat(write_api): new-link modal with alias or generated code`.

---

### Task 7: Environment readiness, image, docs

**Files:**
- Create: `.env.example`, `docs/adr/0008-serve-the-dashboard-as-a-liveview-inside-write-api.md`
- Modify: `Dockerfile`, `docker-compose.yml`, `.gitignore`, `README.md`, `docs/adr/README.md`, `docs/adr/0007-sign-in-with-google-and-keep-sessions-in-a-signed-cookie.md`, `docs/superpowers/specs/2026-11-09-dashboard-api-requirements.md`, `docs/superpowers/specs/2026-11-10-dashboard-ui-design.md` (status line only)

**Interfaces:** none; consumes Tasks 1-6.

- [ ] **Step 1: `Dockerfile`.** After `COPY apps apps`, install and build assets for `write_api` (`mix assets.setup` then `mix assets.deploy`, run in `apps/write_api`) before `mix compile`, so `priv/static` is in the image.
- [ ] **Step 2: `.env.example` and git.** List `GOOGLE_CLIENT_ID`, `SECRET_KEY_BASE`, `SESSION_SECRET`, `SESSION_TTL_SECONDS`, `COOKIE_SECURE`, `DASHBOARD_ORIGIN`, `BASE_URL`, each with a one-line comment and a placeholder value (no real secrets). `.env` goes into `.gitignore`. Compose already reads `.env`; make `SESSION_SECRET` and `SECRET_KEY_BASE` overridable there (`${SESSION_SECRET:-<dev value>}`), keeping the dev defaults so the stack still boots with an empty `.env`.
- [ ] **Step 3: README.** New "Dashboard" section: open `http://localhost:4001/dashboard`; how to create the Google OAuth Client ID (Google Cloud Console, APIs and Services, Credentials, "OAuth client ID", type "Web application", authorised JavaScript origin `http://localhost:4001`, no redirect URI needed); where the value goes (`.env`); that Google accepts only `localhost` or HTTPS origins, so a plain `http://192.168.x.x` address cannot sign in; and the new meaning of `DASHBOARD_ORIGIN`. Update the endpoint table and the env table.
- [ ] **Step 4: ADR 0008** (status `proposed`, date 2026-11-10; follow the format of ADR 0007): the dashboard is a LiveView inside `write_api`, direct calls instead of HTTP, same-origin, why not a separate SPA or separate app. Add it to `docs/adr/README.md`. Correct ADR 0007 and the API requirements doc where they say the dashboard is a separate origin or has its own CORS role: one note each, pointing to ADR 0008. Update the UI design doc's status to "implemented in this branch".
- [ ] **Step 5: Verify the real image.** `docker compose up -d --build`, then: `curl -s -o /dev/null -w '%{http_code} %{content_type}\n' localhost:4001/dashboard` is `200 text/html`; the stylesheet path found in that HTML returns `200 text/css`; `bash scripts/smoke.sh` prints OK; `curl -s localhost:4001/dashboard | grep -c 'not configured\|configurado'` shows the not-configured card when `GOOGLE_CLIENT_ID` is empty.
- [ ] **Step 6: Final checks.** `mix format --check-formatted`; `mix compile --warnings-as-errors --force` in `apps/write_api`; `mix test` (all apps, 0 failures); `git status` shows no stray files (the LAN override and the two older untracked docs are known and stay untouched).
- [ ] **Step 7: Commit** `docs: ADR 0008, dashboard env readiness and README` (the Dockerfile and compose changes go in the same commit or one before it, whichever keeps each commit building).

---

## Self-review notes

- **Spec coverage:** 3.1 → Task 4; 3.2 → Task 5; 3.3 → Task 6; section 4 (same-origin, creation result, secrets, sockets, assets, copy) → Tasks 1, 2, 3, 6, 7; section 5 (env readiness) → Tasks 2 and 7; acceptance 1 → Task 4, 2 → Task 5, 3 → Task 6, 4 → Task 5, 5 → Task 4 (hook; the endpoint already has tests), 6 → Task 2 (config makes the guard accept the app's own origin; the existing CORS tests pin the foreign-origin refusal), 7 and 9 → Task 7, 8 → Task 7 step 5.
- **Open call made here:** the spec left "default to own origin or accept it in the guard" to the builder. This plan sets `DASHBOARD_ORIGIN` explicitly (defaulting to `http://localhost:<port>` in `runtime.exs`), so the guard code does not change.
- **Not testable in ExUnit:** the Google button itself and the clipboard fallback. Both are checked by hand once a real Client ID exists.
