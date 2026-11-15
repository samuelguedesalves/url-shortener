# Dashboard UI: Design

Date: 2026-11-10
Branch: `feat/visual-dashboard`
Status: implemented on branch feat/visual-dashboard; pending ADR 0008 acceptance
Builds on: [Dashboard API requirements](2026-11-09-dashboard-api-requirements.md) (already implemented) and the [URL shortener design](2026-10-07-url-shortener-design.md) (milestone 5, dashboard).

Marking convention: **[user]** was decided by the user. **[my call]** is the author's choice, open to override.

## 1. Intent

A person signs in with Google and lands on a page that lists the links they own and lets them create a new one, with an alias they choose or a generated code. **[user]**

The project is a portfolio piece, so the dashboard should look finished and be pleasant on a phone, but it stays small. It is the human-facing face of the write path that already exists as a JSON API.

## 2. Goals, non-goals, anti-goals

**Goals**
- G1. After sign-in, show the signed-in user's links in a list and a "+ Novo link" button. **[user]**
- G2. The button opens a modal that creates a link with either a custom alias or a generated code. **[user]**
- G3. Signing in works with a Google OAuth Client ID supplied through environment variables. The project must be ready to receive them: nothing else is needed to turn login on. **[user]**
- G4. Built with Elixir and Phoenix LiveView, inside this project, styled with Tailwind and daisyUI. **[user]**

**Non-goals (this iteration)** **[my call]**
- Editing, deleting or disabling a link. Click counts or any analytics (the pipeline does not exist, ADR 0005).
- Search, filters, sorting other than newest first.
- A development login bypass. Login is real Google only; the LiveView tests use the existing fake verifier. (Consequence: the signed-in screens can only be seen in a browser once a real Client ID is configured.)
- Other login providers, roles, account settings.
- Internationalisation machinery (gettext). Strings live in one place so it can be added later.

**Anti-goals** (a failure even if it technically works)
- A user ever seeing another user's links, or any route that renders the list without a valid session.
- Any way to sign in without a verified Google token, in any environment.
- Changing `redirect_api`.
- Breaking the JSON API or `scripts/smoke.sh`.

## 3. Screens

Mockups were reviewed in the browser companion; these are the decisions.

### 3.1 Signed-out page (`/dashboard`)
**[my call]** A centred card: product name, one line of text, and the Google sign-in button. If `GOOGLE_CLIENT_ID` is not configured, no button is rendered; the card says sign-in is not configured instead. A failed sign-in (invalid token, unverified email, service unavailable) shows a short message on the card. The mapping reuses the API's error codes: 401 `invalid_token`, 503 `unavailable`.

### 3.2 Link list (`/dashboard`, signed in) **[user: compact list]**
- Header: product name, the user's name and picture, a sign-out action. **[my call]**
- Title "Meus links (N)" and the "+ Novo link" button. **[user]** (the count and exact title are **[my call]**; the count is of loaded links, so it says "N+" while more pages exist)
- **Compact list, one column, two lines per link.** **[user]** Line 1: the short code, a tag "alias" or "gerado", and a copy button. Line 2: an arrow, the destination, and the creation date. The same layout on desktop and phone. **[my call]** on exactly which details sit on which line.
- Expired links stay in the list, dimmed, tagged "expirado", with "destino removido" instead of the destination (the API returns `long_url: null`, ADR 0004). No copy button. **[my call]**
- Newest first. Pagination uses the API's cursor with a "Carregar mais" button at the end of the list. **[my call]**
- Empty state: a message and a call to create the first link. **[my call]**
- A newly created link is added to the top of the list from the creation result, without refetching. **[my call]**

### 3.3 "Novo link" modal **[user: selector variant]**
Fields:
- **Destino**: the long URL.
- **Endereço curto**: a two-way selector, "Gerar automaticamente" (default) or "Escolher alias". Choosing "Escolher alias" reveals the alias input. With "Gerar", a muted preview line shows the shape of the address, not a real code. **[my call]** on the preview.
- **Expira em**: optional, default 10 years (what the API does when `ttl_seconds` is omitted). The control (preset choices vs a number field) is left to the builder, within what the API accepts.

Behaviour **[my call]**:
- A client-side check is a convenience only; the server's validation is the truth. The API's errors are shown next to the field they concern: invalid or reserved alias and invalid URL as 422 (`invalid_alias`, `invalid_url`, and the like), a taken alias as 409 with "Esse alias já está em uso". The modal stays open on error.
- On success the modal turns into a confirmation showing the full short link with a copy button and a "Fechar" action, and the new link appears at the top of the list.
- The address prefix shown next to the alias is the **redirect** host (`BASE_URL`), not the write-API host.

## 4. Technical decisions

- **Where it lives [user]:** inside the `write_api` app, route `/dashboard`, same endpoint and port (4001). `dashboard` is already a reserved alias.
- **Data access [my call]:** the LiveView calls the existing modules directly (`WriteApi.Links`, `WriteApi.Shortener`, the user store), not the JSON API over HTTP. The JSON API stays as it is.
- **Session [my call]:** the existing signed `session` cookie is the only session. It must be readable by both the first (HTTP) render and the connected LiveView. A signed-out visit to a LiveView route shows 3.1; it is never a redirect loop. The existing "user no longer exists means signed out" rule applies.
- **Sign-in [my call]:** the Google button runs in the browser and sends the credential to the existing `POST /auth/google` with `fetch`, then reloads `/dashboard`. The page never handles or stores the ID token beyond that call. **Sign-out** is a normal `POST /auth/logout` (a LiveView cannot set cookies), then back to `/dashboard`.
- **Same-origin requests [my call, needs a config change]:** the Origin guard (`WriteApi.Plugs.Cors`) rejects state-changing requests whose `Origin` is not `DASHBOARD_ORIGIN`. A dashboard served from the write API sends its own origin, so `DASHBOARD_ORIGIN` must default to, or the guard must also accept, the app's own origin. Dev and compose set it to `http://localhost:4001`. The decision between those two is the builder's, with a test pinning it.
- **Assets [user: Tailwind, daisyUI; my call: the rest]:** Tailwind and daisyUI, built with the esbuild and tailwind Hex packages, and the Dockerfile compiles the assets so `docker compose up --build` still produces a working image. Light and dark follow the system preference. Everything is served from the app; no CDN at runtime except Google's sign-in script.
- **Creation result [my call]:** the list row needs `created_at`, which `WriteApi.Shortener.create/2` does not return today. It is added to the return value; the JSON API response stays exactly as it is.
- **LiveView secrets and sockets [my call]:** LiveView signs its own session token with `SECRET_KEY_BASE`, which still has a hard-coded default. In `prod` it must be a real key (the app refuses to boot without one, like `SESSION_SECRET`). The LiveView re-verifies the `session` cookie when it mounts instead of trusting a user id carried in the LiveView session, and the socket's `check_origin` is set consistently with the Origin guard decision above.
- **Dependencies:** `phoenix_live_view` and `phoenix_html` (plus the asset packages) are new in `write_api`. `phoenix_live_reload` in dev only.
- **Copy button:** uses the browser clipboard API, which needs a secure context (`localhost` or HTTPS). It must degrade without throwing, for example by selecting the text, when the API is unavailable (plain-http LAN address).

## 5. Environment readiness **[user]**

The user will bring the Google Client ID later. The repo must be ready:
- `GOOGLE_CLIENT_ID` already reaches `write_api` (compose passes `${GOOGLE_CLIENT_ID:-}`). The page also needs it at runtime to render the button; it is public, not a secret. The same runtime value is used for token verification and the button, so they cannot disagree.
- An `.env.example` listing every variable (`GOOGLE_CLIENT_ID`, `SESSION_SECRET` note, `DASHBOARD_ORIGIN`, `COOKIE_SECURE`, `BASE_URL`), and `.env` ignored by git. Compose reads `.env` automatically.
- A README section: how to create the OAuth Client ID in Google Cloud Console (type "Web application"), the authorised JavaScript origin `http://localhost:4001`, where to put the value, and the limit that Google accepts only `localhost` or HTTPS origins, so a plain `http://192.168.x.x` address cannot sign in.
- With the variable empty, everything still starts and 3.1 shows the "not configured" message.

## 6. Acceptance criteria

1. Signed out, `/dashboard` renders 3.1 with no link data and no list. With a `GOOGLE_CLIENT_ID` it contains the Google button configured with that ID; without it, the "not configured" message.
2. Signed in as A, the list shows only A's links; B's links never appear (two-user test). Newest first; expired links show the dimmed state with no destination.
3. Create with a chosen alias: appears at the top with the "alias" tag. Create with "Gerar": a 7-character code with the "gerado" tag. A taken alias keeps the modal open with the conflict message; a reserved or invalid alias shows the validation message.
4. Pagination: with more links than one page, "Carregar mais" appends the next page with no duplicates or gaps.
5. Sign-out clears the cookie and returns to 3.1.
6. A same-origin form or `fetch` POST from the dashboard is not refused by the Origin guard; a foreign origin still is.
7. `mix test` passes without Docker or network (LiveView tests use the fake verifier and in-memory stores), `mix format --check-formatted` passes, and `scripts/smoke.sh` and the JSON API tests are unchanged and green.
8. `docker compose up --build` produces an image that serves `/dashboard` with working styles.
9. A short ADR records "dashboard is a LiveView inside `write_api`", and ADR 0007 and the API requirements doc are corrected where they assume a separate dashboard origin.

## 7. Left to the builder

- LiveView structure: one LiveView with function components, or separate ones for the list and the modal; stream vs list assign.
- How the session reaches the LiveView (a session callback, `on_mount`, or another mechanism), and the sign-in `fetch` wiring.
- The expiry control, exact copy of messages, spacing and daisyUI components.
- Whether `DASHBOARD_ORIGIN` defaults to the own origin or the guard accepts it (see section 4).
- Asset pipeline layout and how daisyUI is vendored.
