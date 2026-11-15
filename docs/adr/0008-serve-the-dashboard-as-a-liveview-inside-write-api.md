---
status: proposed
date: 2026-11-10
decision-makers: "Samuel Guedes"
consulted: ""
informed: ""
---

# Serve the dashboard as a LiveView inside write_api

## Context and Problem Statement

[ADR 0007](0007-sign-in-with-google-and-keep-sessions-in-a-signed-cookie.md) added sign-in and per-user link lists to `write_api`, and assumed a separate dashboard application on its own origin that would call the JSON API with CORS. The dashboard itself is now being built ([design](../superpowers/specs/2026-11-10-dashboard-ui-design.md)). Where does it live, and how does it talk to the write path?

## Decision Drivers

* **Small scope.** The project is a portfolio piece; the dashboard is one page with a list and a "new link" form.
* **Tokens out of reach of page scripts.** ADR 0007's XSS goal still holds: the session credential must not be readable by scripts in the page.
* **No new moving parts.** One more deployable, one more origin and a CORS and `SameSite` story are costs the feature does not earn.
* **The write path already exists.** Creating a link and listing a user's links are functions in `write_api` and `shortener_core`.

## Considered Options

* **LiveView inside `write_api`, calling the existing modules directly (chosen).**
* **A separate SPA on another origin, calling the JSON API.**
* **A separate umbrella app for the dashboard.**
* **Server-rendered controller pages without LiveView.**

## Decision Outcome

Chosen option: "**LiveView inside `write_api`, calling the existing modules directly**", because it needs no second origin or deployable and no HTTP hop between the dashboard and the code it uses.

Rules:

* **Where.** The dashboard is a Phoenix LiveView served by `write_api` at `/dashboard`. The JSON API stays as it is, for API clients.
* **Direct calls.** The LiveView calls the same modules the API controllers call (link creation, the owner's link list, session verification). It does not make HTTP requests to `write_api`.
* **Session credential.** Identity always comes from the `session` cookie, re-verified when the LiveView mounts. The raw cookie value never reaches the page: the page carries only an encrypted copy of the session token in the live session, so the ADR 0007 goal (page scripts cannot read the credential) is kept. LiveView's own CSRF token lives in a separate cookie and never carries identity.
* **Same origin.** The page, the websocket and the API share one origin, set by `DASHBOARD_ORIGIN`. The CORS and POST-origin code from ADR 0007 is no longer used by the dashboard, but stays for API clients. The websocket origin check normalises case and default ports; the CORS and POST guard compares the configured string exactly.
* **Sign-in.** The Google button's callback runs `fetch` to `POST /auth/google`, which sets the `session` cookie as before; the page then reloads into the signed-in view. The ID token is only forwarded, never stored or logged.
* **Assets.** Tailwind and daisyUI (vendored) and esbuild produce `priv/static/assets`, which `write_api` serves itself. The Docker build runs `mix assets.setup` and `mix assets.deploy`.

### Consequences

* Good, because there is one deployable and one origin: no CORS for the dashboard, and `SameSite=Lax` is enough.
* Good, because the dashboard cannot drift from the API's rules: it runs the same code.
* Good, because the session credential stays out of page scripts, as ADR 0007 intended.
* Bad, because the image needs the asset pipeline: the build downloads the Tailwind and esbuild binaries.
* Bad, because Google sign-in works only on `localhost` or HTTPS origins; a plain `http://192.168.x.x` address renders the page but cannot sign in.
* Bad, because sessions are still not revocable before they expire (ADR 0007), and an open dashboard page keeps working after logout elsewhere until it is reloaded.
* Bad, because the dashboard is coupled to `write_api`: scaling or deploying the UI independently would mean moving it out.
* Neutral, because `DASHBOARD_ORIGIN` now means "the origin this service is served from", and must be written exactly as the browser shows it.

## Implementation Plan

* **Affected paths**:
  * `apps/write_api/lib/write_api/dashboard/` and `apps/write_api/assets/`: the LiveView, its components and the asset sources.
  * `apps/write_api/mix.exs`, `config/config.exs`, `config/prod.exs`: asset aliases, esbuild and tailwind config, the digest manifest.
  * `Dockerfile`, `docker-compose.yml`, `.env.example`, `README.md`.
* **Dependencies**: `phoenix_live_view`, `phoenix_html`, `esbuild` and `tailwind` (build only), `lazy_html` (tests).
* **Patterns to follow**: the LiveView reads the session once on mount and keeps the credential server side.
* **Patterns to avoid**: rendering the raw session value into HTML, a hidden input, a `phx-value-*`, a pushed event or a log line.
* **Configuration**: `DASHBOARD_ORIGIN` (the origin write_api is served from), `SECRET_KEY_BASE` (signs LiveView tokens), plus ADR 0007's variables.
* **Migration steps**: none.

### Verification

- [ ] In the built image, `GET /dashboard` returns 200 `text/html`, and the stylesheet and script it links to return 200 `text/css` and `text/javascript`.
- [ ] With `GOOGLE_CLIENT_ID` empty, the page shows the "login not configured" card.
- [ ] The raw session cookie value does not appear in the rendered signed-in HTML.
- [ ] A websocket from another origin is refused; `POST /urls` with a foreign `Origin` still returns 403 `forbidden_origin`.
- [ ] `scripts/smoke.sh` still passes.

## Pros and Cons of the Options

### LiveView inside `write_api`

* Good, because it is one service, one origin and no HTTP hop, with server-side state the browser cannot tamper with.
* Bad, because it ties the UI to `write_api` and adds an asset build to the image.

### A separate SPA on another origin

* Good, because UI and API deploy and scale independently.
* Bad, because it needs CORS with credentials and a shared-site `SameSite` setup (ADR 0007's "bad" consequence), plus a JavaScript build, client-side session handling and a second deployable.

### A separate umbrella app

* Good, because it keeps UI code out of `write_api`.
* Bad, because it either runs as a second service with the SPA's costs or must be mounted into `write_api`'s endpoint anyway, adding structure without a benefit at this size.

### Server-rendered controller pages without LiveView

* Good, because it needs no websocket and almost no JavaScript.
* Bad, because paging, the new-link modal and inline alias-taken feedback would need full page loads or hand-written JavaScript, which LiveView provides.

## More Information

* Revisit if: the UI needs to deploy or scale apart from the write path, sessions need immediate revocation, or the service moves behind HTTPS and a real domain (which lifts the `localhost` sign-in limit).
* Design: [Dashboard UI design](../superpowers/specs/2026-11-10-dashboard-ui-design.md).
