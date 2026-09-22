#!/usr/bin/env bash
# Build a sideload .ipk that this LG TV can run.
#
# Two packages, two jobs.
#
# Stremio (default), from spcljense/stremio-webos. The upstream release does
# not work here. It needs two changes:
#   1. armhf ffmpeg. The TV runs a 32-bit userspace (armv7l). Upstream
#      ships arm64 binaries, which cannot execute.
#   2. A new proxy target. The bundled server makes the TV the torrent
#      peer. We forward to the homelab server instead.
#   3. No local server at all. The Stremio core defaults its "Server"
#      setting to 127.0.0.1:11470, so the TV would still torrent unless
#      someone edits that by hand. We keep the bundled server off and
#      listen on 11470 ourselves, so both addresses reach the homelab.
#      Skipped when UPSTREAM_HOST is loopback, or with --dual.
#
# --dual keeps the upstream remote but leaves the bundled server running:
#   8080  -> homelab      11470 -> the TV itself
# You then choose in the app under Settings -> Server. Note the core
# DEFAULTS to 11470, so an unset profile silently torrents on the TV.
#
# Wrapper (--wrapper), from Balazsmi/Stremio-LG-TV. The fallback app. It runs
# as published. The repack only strips the author's .git directory, which is
# 308 KB of the 384 KB installed.
#
# Usage:
#   ./build-stremio.sh                    # Stremio, pinned version
#   ./build-stremio.sh 1.2.0              # Stremio, another release
#   ./build-stremio.sh --install          # build, install, launch, verify
#   ./build-stremio.sh --wrapper          # the fallback wrapper
#   ./build-stremio.sh --wrapper --install
#   ./build-stremio.sh --dual             # keep the TV server too (see Mod 3)
#
# Override the defaults with environment variables:
#   UPSTREAM_HOST=127.0.0.1 ./build-stremio.sh   # keep the server on the TV
#   DEVICE=myTV ./build-stremio.sh
set -euo pipefail

MODE="stremio"
VERSION=""
INSTALL=""
MOD3="yes"

# Print the header comment, however long it grows.
usage() { sed -n '2,/^set -/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'; }

for arg in "$@"; do
    case "$arg" in
        --wrapper)  MODE="wrapper" ;;
        --install)  INSTALL="yes" ;;
        --dual)     MOD3="no" ;;
        -h|--help)  usage; exit 0 ;;
        -*)         echo "unknown flag: $arg" >&2; echo >&2; usage >&2; exit 2 ;;
        *)          VERSION="$arg" ;;
    esac
done

FFMPEG_VERSION="7.0.2"
FFMPEG_URL="https://johnvansickle.com/ffmpeg/releases/ffmpeg-${FFMPEG_VERSION}-armhf-static.tar.xz"
# That host throttles hard. The tarball is cached in build/ and checked.
FFMPEG_SHA256="7d41f558cb1f3395b313f8ceabed78b3731c79a0962abf405ebb5cd393e93991"

UPSTREAM_HOST="${UPSTREAM_HOST:-192.168.0.100}"
UPSTREAM_PORT="${UPSTREAM_PORT:-11470}"
DEVICE="${DEVICE:-Rehab-LG}"

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$HERE/build"

say() { printf '\n==> %s\n' "$1"; }
die() { printf '\nERROR: %s\n' "$1" >&2; exit 1; }

# Download a release asset once, into build/.
fetch_release() {
    local tag="$1" repo="$2" want="$3"
    if [ ! -f "$want" ]; then
        gh release download "$tag" -R "$repo" -D "$WORK" \
            || die "download failed. Check: gh release list -R $repo"
    fi
    [ -f "$want" ] || die "expected $want after downloading $tag from $repo"
}

# Unpack an .ipk into build/src.
unpack() {
    SRC="$WORK/src"
    rm -rf "$SRC" && mkdir -p "$SRC"
    ( cd "$SRC" && ar x "$1" && tar xzf data.tar.gz )
}

mkdir -p "$WORK"

######################################################################
# Stremio
######################################################################
build_stremio() {
    REPO="spcljense/stremio-webos"
    APP_ID="io.strem.webos"
    VERSION="${VERSION:-1.1.5}"
    local svc="usr/palm/services/${APP_ID}.server"
    local app="usr/palm/applications/${APP_ID}"

    say "Downloading ${REPO} v${VERSION}"
    local ipk="$WORK/${APP_ID}_${VERSION}_all.ipk"
    fetch_release "v${VERSION}" "$REPO" "$ipk"

    say "Unpacking"
    unpack "$ipk"
    [ -d "$SRC/$svc" ] || die "layout changed: $svc is missing. Inspect $SRC."

    say "Fetching armhf ffmpeg ${FFMPEG_VERSION}"
    local tarball="$WORK/ffmpeg-${FFMPEG_VERSION}-armhf.tar.xz"
    verify_tarball() { echo "$FFMPEG_SHA256  $tarball" | sha256sum -c --status 2>/dev/null; }
    if verify_tarball; then
        echo "    cached, checksum matches"
    else
        rm -f "$tarball"
        # The host often drops to 10 KB/s. Resume, and give it room.
        curl -fL --retry 5 --retry-delay 5 -C - --progress-bar \
            -o "$tarball" "$FFMPEG_URL" || die "ffmpeg download failed"
        verify_tarball || die "checksum mismatch. Delete $tarball and retry."
    fi
    local ff="$WORK/ff"
    rm -rf "$ff" && mkdir -p "$ff"
    tar xJ --strip-components=1 -f "$tarball" -C "$ff" \
        "ffmpeg-${FFMPEG_VERSION}-armhf-static/ffmpeg" \
        "ffmpeg-${FFMPEG_VERSION}-armhf-static/ffprobe"

    say "Mod 1: swapping ffmpeg for the armhf build"
    cp "$ff/ffmpeg" "$ff/ffprobe" "$SRC/$svc/bin/"
    chmod +x "$SRC/$svc/bin/ffmpeg" "$SRC/$svc/bin/ffprobe"
    local b
    for b in ffmpeg ffprobe; do
        file "$SRC/$svc/bin/$b" | grep -q "ELF 32-bit.*ARM" \
            || die "$b is not a 32-bit ARM binary. The TV cannot run it."
        printf '    %-8s %s\n' "$b" "$(file -b "$SRC/$svc/bin/$b" | cut -d, -f1-2)"
    done

    if [ "$MOD3" = "yes" ]; then
        say "Mod 2 + 3: routing everything to ${UPSTREAM_HOST}:${UPSTREAM_PORT}"
    else
        say "Mod 2 only: proxy -> ${UPSTREAM_HOST}:${UPSTREAM_PORT}, TV server kept on 11470"
    fi
    UPSTREAM_HOST="$UPSTREAM_HOST" UPSTREAM_PORT="$UPSTREAM_PORT" APPLY_MOD3="$MOD3" \
    python3 - "$SRC/$svc/launch.js" <<'PY'
import os, re, sys

path = sys.argv[1]
host = os.environ["UPSTREAM_HOST"]
port = os.environ["UPSTREAM_PORT"]
s = open(path).read()

if "UPSTREAM_HOST" in s:
    sys.exit("launch.js already carries the patch")

anchor = "var streamingReady = false;"
if anchor not in s:
    sys.exit("anchor %r is gone. Re-read launch.js and update this script." % anchor)

s = s.replace(anchor, anchor + """

// Upstream Stremio server. The homelab does the torrenting, not the TV.
// The page stays on 127.0.0.1:8080, so this proxy keeps it same-origin
// and the upstream never needs to send a CORS header.
var UPSTREAM_HOST = '%s';
var UPSTREAM_PORT = %s;
var UPSTREAM_IS_LOCAL = (UPSTREAM_HOST === '127.0.0.1' || UPSTREAM_HOST === 'localhost');
var shadow = null;""" % (host, port), 1)

s = s.replace(
    "// Proxies video/API traffic to 127.0.0.1:11470 with backpressure & abort handling",
    "// Proxies video/API traffic to the upstream server with backpressure & abort handling", 1)

hosts = s.count("host = '127.0.0.1:11470';")
s = s.replace("host = '127.0.0.1:11470';", "host = UPSTREAM_HOST + ':' + UPSTREAM_PORT;")

blocks = len(re.findall(r"hostname: '127\.0\.0\.1',(\s*)port: 11470,", s))
s = re.sub(r"hostname: '127\.0\.0\.1',(\s*)port: 11470,",
           r"hostname: UPSTREAM_HOST,\1port: UPSTREAM_PORT,", s)

if hosts != 2 or blocks != 2:
    sys.exit("expected 2 host headers and 2 hostname/port blocks, found %d and %d. "
             "The upstream proxy changed; read launch.js before you trust this." % (hosts, blocks))

code = "\n".join(l for l in s.splitlines() if not l.strip().startswith("//"))
if "127.0.0.1:11470" in code or "port: 11470" in code:
    sys.exit("a hard-coded 127.0.0.1:11470 survived the patch")

print("    2 host headers and 2 hostname/port blocks rewritten")

# ---- Mod 3: never let the TV serve ----------------------------------
if os.environ.get("APPLY_MOD3") != "yes":
    open(path, "w").write(s)
    print("    Mod 3 skipped: the bundled server keeps 11470")
    sys.exit(0)

# The core builds stream URLs from the "Server" setting, which defaults to
# 127.0.0.1:11470 -- the bundled server. A user who never edits that setting
# silently torrents on the TV. So when the upstream is remote: do not start
# the bundled server at all, and listen on 11470 ourselves, proxying to the
# upstream. Then both addresses reach the homelab and the TV cannot torrent.
old_boot = """    setImmediate(function() {
        try {
            require('./server.js');
        } catch (e) {
            console.error('Failed to load Stremio server.js:', e);
        }
    });"""
new_boot = """    setImmediate(function() {
        if (!UPSTREAM_IS_LOCAL) {
            // The upstream serves. Keep the bundled server off, and shadow
            // its port so a client still pointing at 127.0.0.1:11470 is
            // proxied to the upstream as well.
            shadow = http.createServer(function(req, res) {
                proxyToStreaming(req, res);
            });
            shadow.on('error', function(e) {
                console.error('Shadow listener on 11470 failed:', e.message);
            });
            shadow.listen(11470, '127.0.0.1');
            return;
        }
        try {
            require('./server.js');
        } catch (e) {
            console.error('Failed to load Stremio server.js:', e);
        }
    });"""
if old_boot not in s:
    sys.exit("the server.js boot block changed. Read launch.js and update Mod 3.")
s = s.replace(old_boot, new_boot, 1)

old_term = """    try { server.close(); } catch (_) {}
    process.exit(0);"""
new_term = """    try { server.close(); } catch (_) {}
    try { if (shadow) shadow.close(); } catch (_) {}
    process.exit(0);"""
if old_term not in s:
    sys.exit("the SIGTERM handler changed. Read launch.js and update Mod 3.")
s = s.replace(old_term, new_term, 1)

if s.count("shadow.listen(11470") != 1:
    sys.exit("Mod 3 did not apply cleanly")
print("    bundled server disabled; 11470 shadowed to the upstream")

open(path, "w").write(s)
PY

    say "Packaging"
    OUT="$HERE/${APP_ID}_${VERSION}_all.ipk"
    rm -f "$OUT"
    # --no-minify is not optional. ares-package minifies JavaScript by
    # default, which can undo the patch above.
    ( cd "$SRC" && ares-package --no-minify "$app" "$svc" -o "$HERE" ) >/dev/null
}

######################################################################
# Wrapper — the fallback
######################################################################
build_wrapper() {
    REPO="Balazsmi/Stremio-LG-TV"
    APP_ID="org.balazs.stremio-wrapper"
    VERSION="${VERSION:-1.0.0}"
    local app="usr/palm/applications/${APP_ID}"

    say "Downloading ${REPO} v${VERSION}"
    local ipk="$WORK/${APP_ID}_${VERSION}_all.ipk"
    fetch_release "v${VERSION}" "$REPO" "$ipk"

    say "Unpacking"
    unpack "$ipk"
    [ -d "$SRC/$app" ] || die "layout changed: $app is missing. Inspect $SRC."

    say "Stripping the author's .git directory"
    local before
    before=$(find "$SRC/$app/.git" -type f 2>/dev/null | wc -l)
    if [ "$before" -eq 0 ]; then
        echo "    none found. Upstream may have fixed it; packaging as-is."
    else
        printf '    removing %s files (%s)\n' "$before" "$(du -sh "$SRC/$app/.git" | cut -f1)"
        rm -rf "$SRC/$app/.git"
        [ -e "$SRC/$app/.git" ] && die ".git survived the strip"
    fi

    say "Packaging"
    OUT="$HERE/${APP_ID}_${VERSION}_nogit.ipk"
    rm -f "$OUT"
    local staged="$WORK/wrapper-app"
    rm -rf "$staged" && cp -a "$SRC/$app" "$staged"
    # --no-minify keeps main.js byte-identical to upstream. Without it,
    # ares-package rewrites the back-button handler.
    ( cd "$WORK" && ares-package --no-minify "$staged" -o "$WORK" ) >/dev/null
    local built="$WORK/${APP_ID}_${VERSION}_all.ipk"
    [ -f "$built" ] || die "ares-package produced no $built"
    mv "$built" "$OUT"
    # Put the original download back; the move above consumed its name.
    fetch_release "v${VERSION}" "$REPO" "$ipk"
}

######################################################################

case "$MODE" in
    stremio) build_stremio ;;
    wrapper) build_wrapper ;;
esac

[ -f "$OUT" ] || die "ares-package produced no $OUT"
printf '\nBuilt %s (%s)\n' "$OUT" "$(du -h "$OUT" | cut -f1)"

if [ "$INSTALL" = "yes" ]; then
    say "Installing $APP_ID on $DEVICE"
    ares-launch -d "$DEVICE" --close "$APP_ID" 2>/dev/null || true
    ares-install -d "$DEVICE" "$OUT"
    ares-launch -d "$DEVICE" "$APP_ID"

    if [ "$MODE" = "stremio" ]; then
        say "Checking which server answers"
        sleep 20
        # ssh needs the key passphrase. Load it once with ssh-add to let
        # this run unattended.
        if ssh -o BatchMode=yes tv true 2>/dev/null; then
            for p in 8080 11470; do
                printf '    port %-6s -> ' "$p"
                ssh tv "wget -qO- -T10 http://127.0.0.1:$p/settings" 2>/dev/null \
                    | grep -o '"serverVersion":"[^"]*"\|"cacheRoot":"[^"]*"' | tr '\n' ' '
                echo
            done
            echo
            echo "    Want: cacheRoot /config on BOTH ports."
            echo "    A path under /media/developer means the TV is serving."
        else
            echo "    ssh needs the key passphrase, so skipping the check."
            echo "    Run 'ssh-add ~/.ssh/webos_rsa' and then, by hand:"
            echo
            echo "      for p in 8080 11470; do ssh tv \"wget -qO- http://127.0.0.1:\$p/settings\" \\"
            echo "        | grep -o '\"cacheRoot\":\"[^\"]*\"'; done"
        fi
    fi
fi

if [ "$MODE" = "stremio" ]; then
    if [ "$UPSTREAM_HOST" = "127.0.0.1" ] || [ "$UPSTREAM_HOST" = "localhost" ]; then
        echo
        echo "The bundled server runs on the TV. The TV torrents."
    elif [ "$MOD3" = "no" ]; then
        cat <<EOF

Two servers, and you choose:
  http://127.0.0.1:8080/   -> ${UPSTREAM_HOST}:${UPSTREAM_PORT} (homelab)
  http://127.0.0.1:11470/  -> the TV itself

Set it in the app: Settings -> Server -> EDIT_URL.
The core DEFAULTS to 11470, so leaving it unset makes the TV torrent.
Check which one is working during playback:

  curl -s http://${UPSTREAM_HOST}:${UPSTREAM_PORT}/stats.json | grep -o '"selections":\[[^]]*'
EOF
    else
        cat <<EOF

The app needs no Server setting. Both 127.0.0.1:8080 and 127.0.0.1:11470
now reach ${UPSTREAM_HOST}:${UPSTREAM_PORT}, so the TV cannot torrent.
EOF
    fi
fi
