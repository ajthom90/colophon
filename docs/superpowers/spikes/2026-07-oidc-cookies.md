# Spike: are cookies load-bearing for ABS's OIDC callback?

**Date:** 2026-07-07
**Task:** M1b Task 5 — Dex IdP + ABS OIDC configuration + cookie spike
**Answers M0's open question:** does `GET /auth/openid/callback` require cookies from the
initial `GET /auth/openid`? What exactly must the client carry?

## THE ANSWER: YES — cookies are load-bearing

`GET /auth/openid/callback?state&code&code_verifier` **hard-fails with `400 "No session"`**
unless the request carries the cookies set by the initial `GET /auth/openid` 302 response.
Verified empirically both ways with the same authorization code (the WITHOUT attempt was run
FIRST, so the code was still unconsumed for the WITH attempt — the session check precedes the
token exchange in the server code, so the failed attempt does not burn the code):

| Callback request              | Result |
|-------------------------------|--------|
| Fresh cookie jar (no cookies) | `400 Bad Request`, body `No session` |
| App jar from step 1           | `200 OK`, full JSON login response, `accessToken` + `refreshToken` present |

**What the client must carry** (both set on the step-1 302, both `HttpOnly`):

- `connect.sid` — express-session cookie. The server stores the entire OIDC transaction in
  `req.session[sessionKey]`: `state`, `sso_redirect_uri`, `mobile` flag. The callback route's
  first act is `if (!req.session[sessionKey]) return res.status(400).send('No session')`
  (`/app/server/Auth.js`, callback route), and passport re-sends
  `req.session[sessionKey].sso_redirect_uri` in the token request.
- `auth_method=openid-mobile` — selects the response mode in
  `handleLoginSuccessBasedOnCookie`: `openid-mobile` is "API-based", so the callback answers
  with **JSON including the refresh token**; without it the server treats the login as a web
  flow and tries to redirect to an `auth_cb` cookie URL (`400 "No callback or already expired"`
  when absent).

**Implication for Task 6 (`OIDCFlow`):** the dedicated cookie-jar URLSession is REQUIRED, not
belt-and-braces. Step 1 (`GET /auth/openid`, redirects disabled) and the final callback exchange
MUST share the same jar. The browser (ASWebAuthenticationSession) needs NO cookie continuity
with that session: the browser-side hops (Dex pages, `/auth/openid/mobile-redirect`) are
session-independent — `mobile-redirect` resolves `state → colophon://oauth` through a
server-side in-memory map (`openIdAuthSession`), not the express session. The spike simulated
this exactly: separate "app" and "browser" jars, and the browser jar never saw `connect.sid`.

## Networking outcome: preferred design WON

Issuer: **`http://host.docker.internal:5556/dex`** — the same URL validates everywhere:

- **ABS container → Dex:** Docker Desktop resolves `host.docker.internal` natively inside
  containers; the container hits the host, which forwards to dex's published port 5556.
  Verified: `docker exec colophon-abs wget -qO- http://host.docker.internal:5556/dex/.well-known/openid-configuration` returns the discovery doc.
- **Host/simulator browser → Dex:** required the one-time host mapping
  `echo "127.0.0.1 host.docker.internal" | sudo tee -a /etc/hosts` (run by the user after a
  NEEDS_CONTEXT pause — the host cannot otherwise resolve the name). Verified:
  `curl http://host.docker.internal:5556/dex/.well-known/openid-configuration` from the host.
- The fallback design (`extra_hosts: ["localhost:host-gateway"]`) was NOT needed.

Dex image pinned: **`ghcr.io/dexidp/dex:v2.45.1`** (current stable, released 2026-03-03;
digest `sha256:8499afd690c437f52301efd2b05b2455da5bd2dfc20332cd697dc9937f808462`).
The bcrypt hash for the static password was generated with
`htpasswd -bnBC 10 "" colophon-oidc | tr -d ':\n'` (produces a `$2y$` hash — dex's Go
bcrypt accepts it; verified by the successful form login below).

## ABS OIDC settings: endpoint + exact working payload

Endpoint (discovered in `/app/server/routers/ApiRouter.js` of the v2.35.1 container — NOT
`PATCH /api/settings` as the plan guessed):

```
GET   /api/auth-settings      (admin; returns authenticationSettings)
PATCH /api/auth-settings      (admin; per-key compare-and-set, returns {updated, serverSettings})
```

The exact payload that works (now applied idempotently by `devserver/seed.sh` — re-PATCHing
identical values yields `{"updated": false}` and no side effects):

```json
{
  "authActiveAuthMethods": ["local", "openid"],
  "authOpenIDIssuerURL": "http://host.docker.internal:5556/dex",
  "authOpenIDAuthorizationURL": "http://host.docker.internal:5556/dex/auth",
  "authOpenIDTokenURL": "http://host.docker.internal:5556/dex/token",
  "authOpenIDUserInfoURL": "http://host.docker.internal:5556/dex/userinfo",
  "authOpenIDJwksURL": "http://host.docker.internal:5556/dex/keys",
  "authOpenIDClientID": "audiobookshelf",
  "authOpenIDClientSecret": "colophon-dex-secret",
  "authOpenIDTokenSigningAlgorithm": "RS256",
  "authOpenIDButtonText": "Sign in with Dex",
  "authOpenIDAutoLaunch": false,
  "authOpenIDAutoRegister": true,
  "authOpenIDSubfolderForRedirectURLs": "",
  "authOpenIDMobileRedirectURIs": ["colophon://oauth"]
}
```

Empirically discovered gotchas (all bit during the spike):

1. **ABS does NOT run issuer discovery.** `OidcAuthStrategy.getClient()` constructs the
   `openid-client` Issuer from the five individually configured URLs; `isOpenIDAuthSettingsValid`
   requires issuer + authorization + token + userinfo + jwks + clientID + clientSecret +
   signing algorithm. Setting only `authOpenIDIssuerURL` leaves openid silently deactivated.
2. **`authOpenIDSubfolderForRedirectURLs` MUST be explicitly `""`.** It defaults to `undefined`
   in a fresh 2.35.1 install, and the server string-interpolates it into the redirect URI —
   producing `http://localhost:13378/undefined/auth/openid/mobile-redirect`, which Dex rejects
   with "Unregistered redirect_uri". (The normal web admin UI sets it; a pure-API setup must
   too. This key is the one field where `""` is preserved rather than coerced to `null`.)
3. **`authOpenIDAutoRegister: true` is required** for the flow to complete: the Dex user
   `oidc@colophon.dev` has no pre-existing ABS account, and without auto-register the callback
   fails after token exchange with "user not found". (Beyond the brief's minimum list, but
   load-bearing; recorded here deliberately.)
4. **Dex `oauth2.skipApprovalScreen: true`** added to `devserver/dex/config.yaml` (deviation
   from the plan's starting-point config): without it the code flow parks on Dex's interactive
   "Grant Access" page after login. With it, the credentials POST 303s straight to ABS's
   `mobile-redirect` — better for both the spike and the real app UX.
5. The step-1 mobile flow is triggered by ANY of `response_type=code` / `redirect_uri` /
   `code_challenge` being present; `code_challenge` is REQUIRED (`400` otherwise) and only
   `S256` is accepted. The server generates `state` itself when the client sends none —
   Task 6's "extract state from the 302 Location" design is correct.

## Verified end state

- `GET /status` → `authMethods: ["local", "openid"]`,
  `authFormData.authOpenIDButtonText: "Sign in with Dex"`, `authOpenIDAutoLaunch: false`.
- Password login regression: `POST /login` (`root`/`colophon-dev`, `x-return-tokens: true`)
  still returns `accessToken` + `refreshToken`. (Per coordinator constraint the Swift contract
  suite was NOT run in this task — another agent held the ABSKit tree; the controller runs it
  after both tasks land.)
- `devserver/seed.sh` re-run twice: configures from a reset state, no-ops when already
  configured, and self-verifies the `/status` shape.

## Full transcript (final run, seeded state)

Two jars: `APP_JAR` simulates the app's URLSession (steps 1, 7a/7b); `BROWSER_JAR` simulates
ASWebAuthenticationSession (steps 2–5). PKCE verifier = 84 hex chars (42 random bytes),
challenge = base64url(SHA256(verifier)), no padding.

```
== PKCE ==
verifier=3cc43a5febd96be63075e3b3070630d8bb87ba521783140b2b3e97524140393574a36c77517cd436e9a1
challenge=EwTofiVETBrJyDwzeZXakxgxLedVjjDi5VtsEPNz0bE

== STEP 1: GET /auth/openid (APP jar, no redirect follow) ==
GET http://localhost:13378/auth/openid?response_type=code&redirect_uri=colophon%3A%2F%2Foauth
    &client_id=Colophon&code_challenge=EwTofi...&code_challenge_method=S256
HTTP/1.1 302 Found
Set-Cookie: auth_method=openid-mobile; Max-Age=315360000; Path=/; HttpOnly
Set-Cookie: connect.sid=s%3AxT-TC6MeoyCIXBCmhn45ijgRjmopPIb-.Kr9nSAUom7hsWGxts4gKAiUSlwVhV03VHO8VpzgQfCE; Path=/; HttpOnly
Location: http://host.docker.internal:5556/dex/auth?client_id=audiobookshelf
    &scope=openid%20profile%20email&response_type=code
    &redirect_uri=http%3A%2F%2Flocalhost%3A13378%2Fauth%2Fopenid%2Fmobile-redirect
    &state=PVveOPj8lj8KfMufvrIk35Vd0Bo5vPT1KbGLXZ5Ikis
    &code_challenge=EwTofiVETBrJyDwzeZXakxgxLedVjjDi5VtsEPNz0bE&code_challenge_method=S256

APP JAR after step 1:
#HttpOnly_localhost  FALSE  /  FALSE  0           connect.sid  s%3AxT-TC6...
#HttpOnly_localhost  FALSE  /  FALSE  2098790495  auth_method  openid-mobile

== STEP 2: browser GET dex authorize URL (BROWSER jar) ==
HTTP/1.1 302 Found
Location: /dex/auth/local?client_id=audiobookshelf&code_challenge=EwTofi...&state=PVveOP...

== STEP 2b: browser GET connector URL -> login page redirect ==
HTTP/1.1 302 Found
Location: /dex/auth/local/login?back=&state=g6ibarieelzi4ufrjv4lfgg5w

== STEP 3: browser GET dex login form ==
HTTP/1.1 200 OK
<form method="post" action="/dex/auth/local/login?back=&amp;state=g6ibarieelzi4ufrjv4lfgg5w">

== STEP 4: browser POST credentials (login=oidc@colophon.dev, password=colophon-oidc) ==
HTTP/1.1 303 See Other          <- skipApprovalScreen: straight to the client redirect_uri
Location: http://localhost:13378/auth/openid/mobile-redirect?code=abnbmglpz4pfh2nokyt6dml5a
    &state=PVveOPj8lj8KfMufvrIk35Vd0Bo5vPT1KbGLXZ5Ikis

== STEP 5: browser GET /auth/openid/mobile-redirect (BROWSER jar — no ABS session cookie!) ==
HTTP/1.1 302 Found
Location: colophon://oauth?code=abnbmglpz4pfh2nokyt6dml5a&state=PVveOPj8lj8KfMufvrIk35Vd0Bo5vPT1KbGLXZ5Ikis

extracted code=abnbmglpz4pfh2nokyt6dml5a
extracted state=PVveOPj8lj8KfMufvrIk35Vd0Bo5vPT1KbGLXZ5Ikis

== STEP 7a: GET /auth/openid/callback?state&code&code_verifier WITHOUT cookies (fresh jar, run FIRST) ==
HTTP/1.1 400 Bad Request
body: No session

== STEP 7b: same URL WITH the APP cookie jar (same, still-unconsumed code) ==
HTTP/1.1 200 OK
Set-Cookie: openid_id_token=eyJhbGciOiJSUzI1NiIs... (HttpOnly; Secure; SameSite=Strict)
Set-Cookie: connect.sid=s%3A_6mEfK0Lpp... (rotated)
Content-Type: application/json; charset=utf-8
login response keys: ['Source', 'ereaderDevices', 'serverSettings', 'user', 'userDefaultLibraryId']
username: oidc | type: user
accessToken present: True | refreshToken present: True
```

Note on step 7b's response: the body is the same `LoginResponse` shape as `POST /login`
(`user.accessToken`, `user.refreshToken`, `userDefaultLibraryId`, `serverSettings`), so
Task 6's `authenticate` can decode it with the existing DTO. The `openid_id_token` cookie is
set `Secure` (dropped over plain http) — irrelevant to the flow; the tokens live in the JSON.

## Environment

- ABS: `ghcr.io/advplyr/audiobookshelf:2.35.1` (`colophon-abs`, `http://localhost:13378`)
- Dex: `ghcr.io/dexidp/dex:v2.45.1` (`colophon-dex`, port 5556, memory storage,
  static client `audiobookshelf` / `colophon-dex-secret`,
  static user `oidc@colophon.dev` / `colophon-oidc`)
- Host: macOS with `127.0.0.1 host.docker.internal` in `/etc/hosts`; Docker Desktop
  (server 29.6.1); curl cookie-jar simulation, zero Swift code involved
