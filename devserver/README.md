# Colophon dev server

`make server-up && make seed` → Audiobookshelf 2.35.1 at http://localhost:13378
(root / colophon-dev) with one library ("Books") containing a multi-file
LibriVox audiobook. `make server-down` stops it; delete `devserver/data/` for
a factory reset. Contract tests use `ABS_CONTRACT_URL=http://localhost:13378`.
Simulators reach it via localhost; a physical device needs your Mac's LAN IP.

OIDC: a Dex IdP (`colophon-dex`, pinned `ghcr.io/dexidp/dex:v2.45.1`) runs on
port 5556 with issuer `http://host.docker.internal:5556/dex`; the seed activates
openid alongside local auth (test user `oidc@colophon.dev` / `colophon-oidc`).
One-time host setup so browsers/simulators can resolve the issuer:
`echo "127.0.0.1 host.docker.internal" | sudo tee -a /etc/hosts`.
See docs/superpowers/spikes/2026-07-oidc-cookies.md for the flow details.
