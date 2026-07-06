#!/usr/bin/env bash
# Seeds the dev ABS server: root user, one library, one public-domain multi-file audiobook.
set -euo pipefail
BASE="http://localhost:13378"
USER="root"
PASS="colophon-dev"
BOOK_DIR="$(dirname "$0")/data/audiobooks/Sun Tzu/The Art of War"

echo "→ waiting for server"
TIMEOUT=120
ELAPSED=0
until curl -fsS "$BASE/status" >/dev/null 2>&1; do
  sleep 1
  ELAPSED=$((ELAPSED + 1))
  if [ $ELAPSED -ge $TIMEOUT ]; then
    echo "✗ server did not respond within ${TIMEOUT}s. Check status: docker compose -f devserver/docker-compose.yml logs"
    exit 1
  fi
done

IS_INIT=$(curl -fsS "$BASE/status" | python3 -c 'import json,sys; print(json.load(sys.stdin)["isInit"])')
if [ "$IS_INIT" = "False" ] || [ "$IS_INIT" = "false" ]; then
  echo "→ initializing root user"
  curl -fsS -X POST "$BASE/init" -H 'Content-Type: application/json' \
    -d "{\"newRoot\":{\"username\":\"$USER\",\"password\":\"$PASS\"}}" >/dev/null
fi

if [ ! -d "$BOOK_DIR" ]; then
  echo "→ downloading The Art of War (LibriVox, public domain)"
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  curl -fL --retry 3 --connect-timeout 15 --max-time 600 "https://archive.org/download/art_of_war_librivox/art_of_war_librivox_64kb_mp3.zip" -o "$TMP/book.zip"
  unzip -q "$TMP/book.zip" -d "$TMP/unzipped"
  mkdir -p "$(dirname "$BOOK_DIR")"
  mv "$TMP/unzipped" "$BOOK_DIR"
fi

echo "→ logging in"
TOKEN=$(curl -fsS -X POST "$BASE/login" -H 'Content-Type: application/json' -H 'x-return-tokens: true' \
  -d "{\"username\":\"$USER\",\"password\":\"$PASS\"}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["user"]["accessToken"])')

LIB_COUNT=$(curl -fsS "$BASE/api/libraries" -H "Authorization: Bearer $TOKEN" \
  | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["libraries"]))')
if [ "$LIB_COUNT" = "0" ]; then
  echo "→ creating Books library"
  curl -fsS -X POST "$BASE/api/libraries" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d '{"name":"Books","mediaType":"book","folders":[{"fullPath":"/audiobooks"}],"provider":"google"}' >/dev/null
fi

LIB_ID=$(curl -fsS "$BASE/api/libraries" -H "Authorization: Bearer $TOKEN" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["libraries"][0]["id"])')
echo "→ scanning library $LIB_ID"
curl -fsS -X POST "$BASE/api/libraries/$LIB_ID/scan" -H "Authorization: Bearer $TOKEN" >/dev/null || true
echo "✓ seeded. Web UI: $BASE ($USER / $PASS)"
