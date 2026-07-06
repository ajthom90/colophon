# Colophon dev server

`make server-up && make seed` → Audiobookshelf 2.35.1 at http://localhost:13378
(root / colophon-dev) with one library ("Books") containing a multi-file
LibriVox audiobook. `make server-down` stops it; delete `devserver/data/` for
a factory reset. Contract tests use `ABS_CONTRACT_URL=http://localhost:13378`.
Simulators reach it via localhost; a physical device needs your Mac's LAN IP.
