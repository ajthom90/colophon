#!/usr/bin/env bash
# Seeds the dev ABS server: root user, an audiobook library (one public-domain
# multi-file audiobook), and a podcast library (a local RSS fixture — see the
# "Podcast library" section). Idempotent: safe to re-run.
set -euo pipefail
BASE="http://localhost:13378"
USER="root"
PASS="colophon-dev"
BOOK_DIR="$(dirname "$0")/data/audiobooks/Sun Tzu/The Art of War"

# Single EXIT cleanup: removes the audiobook-download temp dir ($TMP, set only on
# first run) and stops the transient podcast-feed HTTP server ($FEED_SRV_PID) even
# if the script aborts mid-ingest under `set -e`.
TMP=""
FEED_SRV_PID=""
cleanup() {
  [ -n "$FEED_SRV_PID" ] && kill "$FEED_SRV_PID" 2>/dev/null || true
  [ -n "$TMP" ] && rm -rf "$TMP" || true
}
trap cleanup EXIT

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
  curl -fL --retry 3 --connect-timeout 15 --max-time 600 "https://archive.org/download/art_of_war_librivox/art_of_war_librivox_64kb_mp3.zip" -o "$TMP/book.zip"
  unzip -q "$TMP/book.zip" -d "$TMP/unzipped"
  mkdir -p "$(dirname "$BOOK_DIR")"
  mv "$TMP/unzipped" "$BOOK_DIR"
fi

COVER="$BOOK_DIR/cover.jpg"
if [ ! -f "$COVER" ]; then
  echo "→ downloading cover art"
  curl -fsSL --retry 3 --connect-timeout 15 --max-time 120 \
    "https://archive.org/services/img/art_of_war_librivox" -o "$COVER" \
    || echo "⚠ cover download failed — continuing without cover"
  [ -s "$COVER" ] || rm -f "$COVER"
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
  | python3 -c 'import json,sys; print(next(l["id"] for l in json.load(sys.stdin)["libraries"] if l["mediaType"]=="book"))')
echo "→ scanning library $LIB_ID"
curl -fsS -X POST "$BASE/api/libraries/$LIB_ID/scan" -H "Authorization: Bearer $TOKEN" >/dev/null || true

# --- Podcast library + local RSS fixture -------------------------------------
# Seeds a deterministic, public-internet-INDEPENDENT podcast: a hand-authored RSS
# feed (generated below) whose enclosures REUSE the already-downloaded Art of War
# mp3s, served from a TRANSIENT localhost HTTP server that ABS fetches via
# host.docker.internal. ABS's SSRF filter blocks private IPs by default, so
# docker-compose.yml whitelists host.docker.internal (SSRF_REQUEST_FILTER_WHITELIST).
# The only network dependency is host↔container loopback (Docker Desktop), NOT the
# public internet. Idempotent: ingest is skipped once the podcast has its episodes.
PODCAST_FEEDSRC="$(dirname "$0")/data/podcasts_feedsrc"
FEED_PORT=8199
FEED_BASE="http://host.docker.internal:$FEED_PORT"

PODCAST_LIB_ID=$(curl -fsS "$BASE/api/libraries" -H "Authorization: Bearer $TOKEN" \
  | python3 -c 'import json,sys; print(next((l["id"] for l in json.load(sys.stdin)["libraries"] if l["mediaType"]=="podcast"), ""))')
if [ -z "$PODCAST_LIB_ID" ]; then
  echo "→ creating Podcasts library"
  PODCAST_LIB_ID=$(curl -fsS -X POST "$BASE/api/libraries" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d '{"name":"Podcasts","mediaType":"podcast","folders":[{"fullPath":"/podcasts"}],"provider":"itunes"}' \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
fi

PODCAST_EP_COUNT=$(curl -fsS "$BASE/api/libraries/$PODCAST_LIB_ID/items?limit=50" -H "Authorization: Bearer $TOKEN" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(max([(it.get("media",{}).get("numEpisodes") or 0) for it in d.get("results",[]) if it.get("media",{}).get("metadata",{}).get("title")=="Colophon Test Podcast"] or [0]))')

if [ "${PODCAST_EP_COUNT:-0}" -lt 2 ]; then
  echo "→ ingesting Colophon Test Podcast (local RSS fixture)"
  mkdir -p "$PODCAST_FEEDSRC"
  # Fixed source files → stable episode sizes/durations so the committed test
  # fixtures stay valid across re-seeds.
  cp "$BOOK_DIR/art_of_war_03-04_sun_tzu_64kb.mp3" "$PODCAST_FEEDSRC/episode-1.mp3"
  cp "$BOOK_DIR/art_of_war_01-02_sun_tzu_64kb.mp3" "$PODCAST_FEEDSRC/episode-2.mp3"
  [ -f "$BOOK_DIR/cover.jpg" ] && cp "$BOOK_DIR/cover.jpg" "$PODCAST_FEEDSRC/cover.jpg"
  EP1_LEN=$(wc -c < "$PODCAST_FEEDSRC/episode-1.mp3" | tr -d ' ')
  EP2_LEN=$(wc -c < "$PODCAST_FEEDSRC/episode-2.mp3" | tr -d ' ')
  cat > "$PODCAST_FEEDSRC/feed.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"
     xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"
     xmlns:content="http://purl.org/rss/1.0/modules/content/"
     xmlns:atom="http://www.w3.org/2005/Atom">
  <channel>
    <title>Colophon Test Podcast</title>
    <link>$FEED_BASE/</link>
    <language>en-us</language>
    <itunes:author>Colophon Dev</itunes:author>
    <itunes:type>episodic</itunes:type>
    <itunes:explicit>false</itunes:explicit>
    <description><![CDATA[<p>A tiny <b>public-domain</b> podcast seeded for Colophon dev &amp; tests. Episodes reuse LibriVox <i>Art of War</i> audio.</p>]]></description>
    <itunes:image href="$FEED_BASE/cover.jpg"/>
    <atom:link href="$FEED_BASE/feed.xml" rel="self" type="application/rss+xml"/>
    <itunes:category text="Arts"/>
    <item>
      <title>Episode One: Laying Plans</title>
      <itunes:subtitle>The opening chapter on strategy</itunes:subtitle>
      <description><![CDATA[<p>The <b>first</b> episode. Covers laying plans and waging war. Contains <a href="https://example.com">a link</a> and HTML markup for description rendering tests.</p>]]></description>
      <content:encoded><![CDATA[<p>The <b>first</b> episode. Covers laying plans and waging war. Contains <a href="https://example.com">a link</a> and HTML markup for description rendering tests.</p>]]></content:encoded>
      <pubDate>Mon, 06 Jan 2025 08:00:00 GMT</pubDate>
      <guid isPermaLink="false">colophon-test-ep-0001</guid>
      <itunes:season>1</itunes:season>
      <itunes:episode>1</itunes:episode>
      <itunes:episodeType>full</itunes:episodeType>
      <itunes:duration>0:07:45</itunes:duration>
      <itunes:explicit>false</itunes:explicit>
      <enclosure url="$FEED_BASE/episode-1.mp3" type="audio/mpeg" length="$EP1_LEN"/>
    </item>
    <item>
      <title>Episode Two: Attack by Stratagem</title>
      <itunes:subtitle>Winning without fighting</itunes:subtitle>
      <description><![CDATA[<p>The <b>second</b> episode. On attack by stratagem and the use of energy.</p>]]></description>
      <content:encoded><![CDATA[<p>The <b>second</b> episode. On attack by stratagem and the use of energy.</p>]]></content:encoded>
      <pubDate>Mon, 13 Jan 2025 08:00:00 GMT</pubDate>
      <guid isPermaLink="false">colophon-test-ep-0002</guid>
      <itunes:season>1</itunes:season>
      <itunes:episode>2</itunes:episode>
      <itunes:episodeType>full</itunes:episodeType>
      <itunes:duration>0:08:26</itunes:duration>
      <itunes:explicit>false</itunes:explicit>
      <enclosure url="$FEED_BASE/episode-2.mp3" type="audio/mpeg" length="$EP2_LEN"/>
    </item>
  </channel>
</rss>
EOF
  python3 -m http.server "$FEED_PORT" --bind 0.0.0.0 --directory "$PODCAST_FEEDSRC" >/dev/null 2>&1 &
  FEED_SRV_PID=$!
  disown "$FEED_SRV_PID" 2>/dev/null || true  # silence bash's "Terminated" notice on kill

  # Wait until ABS can actually fetch+parse the feed (host↔container loopback ready).
  FEED_JSON=""
  for _ in $(seq 1 20); do
    if FEED_JSON=$(curl -fsS -X POST "$BASE/api/podcasts/feed" -H "Authorization: Bearer $TOKEN" \
        -H 'Content-Type: application/json' -d "{\"rssFeed\":\"$FEED_BASE/feed.xml\"}" 2>/dev/null) \
        && [ -n "$FEED_JSON" ]; then break; fi
    sleep 1
  done
  if [ -z "$FEED_JSON" ]; then
    echo "✗ ABS could not fetch the podcast feed fixture from $FEED_BASE/feed.xml"
    echo "  Check SSRF_REQUEST_FILTER_WHITELIST=host.docker.internal in docker-compose.yml."
    exit 1
  fi
  printf '%s' "$FEED_JSON" > "$PODCAST_FEEDSRC/feed-parsed.json"

  # Create the podcast item, then queue its episodes for download. The parsed feed
  # is passed as a FILE arg (not stdin) because `python3 -` reads its program from
  # the heredoc, which would otherwise consume stdin.
  python3 - "$BASE" "$TOKEN" "$PODCAST_LIB_ID" "$PODCAST_FEEDSRC/feed-parsed.json" <<'PY'
import json, sys, urllib.request
base, token, lib_id, feed_file = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
feed = json.load(open(feed_file))["podcast"]
def req(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(base + path, data=data, method=method,
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
    with urllib.request.urlopen(r) as resp:
        raw = resp.read().decode()
    try:
        return json.loads(raw)          # download-episodes returns a non-JSON body; ignored
    except json.JSONDecodeError:
        return {}
folder = req("GET", "/api/libraries/" + lib_id)["folders"][0]
meta = feed["metadata"]
created = req("POST", "/api/podcasts", {
    "path": "/podcasts/Colophon Test Podcast",
    "folderId": folder["id"],
    "libraryId": lib_id,
    "media": {"metadata": {
        "title": "Colophon Test Podcast", "author": meta.get("author", "Colophon Dev"),
        "description": meta.get("description"), "feedUrl": meta.get("feedUrl"),
        "imageUrl": meta.get("image"), "language": meta.get("language", "en-us"),
        "explicit": bool(meta.get("explicit", False)), "type": meta.get("type", "episodic")},
        "autoDownloadEpisodes": False}})
req("POST", "/api/podcasts/" + created["id"] + "/download-episodes", feed["episodes"])
PY

  # Wait for episode downloads to land (probe media.numEpisodes).
  N=0
  for _ in $(seq 1 30); do
    N=$(curl -fsS "$BASE/api/libraries/$PODCAST_LIB_ID/items?limit=50" -H "Authorization: Bearer $TOKEN" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(max([(it.get("media",{}).get("numEpisodes") or 0) for it in d.get("results",[]) if it.get("media",{}).get("metadata",{}).get("title")=="Colophon Test Podcast"] or [0]))')
    [ "${N:-0}" -ge 2 ] && break
    sleep 2
  done
  kill "$FEED_SRV_PID" 2>/dev/null || true
  FEED_SRV_PID=""
  echo "  ✓ podcast ingested ($N episodes)"
else
  echo "→ podcast already seeded ($PODCAST_EP_COUNT episodes) — skipping"
fi

# --- OIDC (Dex) --------------------------------------------------------------
# Idempotent: PATCH /api/auth-settings compares each key server-side and
# reports {"updated": false} when nothing changed; re-runs are no-ops.
# Payload discovered empirically against ABS v2.35.1 — see
# docs/superpowers/spikes/2026-07-oidc-cookies.md for endpoint/field notes
# (notably: ABS does NOT run issuer discovery, so every endpoint URL must be
# set explicitly, and authOpenIDSubfolderForRedirectURLs must be "" or the
# server builds redirect URIs with a literal "/undefined/" path segment).
echo "→ configuring OIDC (Dex issuer)"
DEX_ISSUER="http://host.docker.internal:5556/dex"
curl -fsS -X PATCH "$BASE/api/auth-settings" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d @- >/dev/null <<EOF
{
  "authActiveAuthMethods": ["local", "openid"],
  "authOpenIDIssuerURL": "$DEX_ISSUER",
  "authOpenIDAuthorizationURL": "$DEX_ISSUER/auth",
  "authOpenIDTokenURL": "$DEX_ISSUER/token",
  "authOpenIDUserInfoURL": "$DEX_ISSUER/userinfo",
  "authOpenIDJwksURL": "$DEX_ISSUER/keys",
  "authOpenIDClientID": "audiobookshelf",
  "authOpenIDClientSecret": "colophon-dex-secret",
  "authOpenIDTokenSigningAlgorithm": "RS256",
  "authOpenIDButtonText": "Sign in with Dex",
  "authOpenIDAutoLaunch": false,
  "authOpenIDAutoRegister": true,
  "authOpenIDSubfolderForRedirectURLs": "",
  "authOpenIDMobileRedirectURIs": ["colophon://oauth"]
}
EOF

echo "→ verifying auth methods"
curl -fsS "$BASE/status" | python3 -c '
import json, sys
s = json.load(sys.stdin)
methods = s.get("authMethods", [])
button = s.get("authFormData", {}).get("authOpenIDButtonText")
assert "local" in methods and "openid" in methods, f"authMethods wrong: {methods}"
assert button == "Sign in with Dex", f"button text wrong: {button}"
print(f"  authMethods={methods} button={button!r}")
'
echo "✓ seeded. Web UI: $BASE ($USER / $PASS). OIDC: oidc@colophon.dev / colophon-oidc"
