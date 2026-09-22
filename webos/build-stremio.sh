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
#
# Override the defaults with environment variables:
#   UPSTREAM_HOST=127.0.0.1 ./build-stremio.sh   # keep the server on the TV
#   DEVICE=myTV ./build-stremio.sh
set -euo pipefail

MODE="stremio"
VERSION=""
INSTALL=""

usage() { sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; }

for arg in "$@"; do
    case "$arg" in
        --wrapper)  MODE="wrapper" ;;
        --install)  INSTALL="yes" ;;
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

    say "Mod 2: pointing the proxy at ${UPSTREAM_HOST}:${UPSTREAM_PORT}"
    UPSTREAM_HOST="$UPSTREAM_HOST" UPSTREAM_PORT="$UPSTREAM_PORT" \
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
var UPSTREAM_PORT = %s;""" % (host, port), 1)

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

open(path, "w").write(s)
print("    2 host headers and 2 hostname/port blocks rewritten")
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
        ssh tv "wget -qO- http://127.0.0.1:8080/settings" \
            | grep -o '"serverVersion":"[^"]*"\|"cacheRoot":"[^"]*"' \
            || echo "    could not reach the app. Give it a moment and retry."
        echo
        echo "    The homelab reports cacheRoot /config."
        echo "    The bundled server reports a path under /media/developer."
    fi
fi

if [ "$MODE" = "stremio" ]; then
    cat <<'EOF'

Last step, in the app: Settings -> Server -> EDIT_URL -> http://127.0.0.1:8080/
Leave it on loopback. The proxy forwards to the homelab.
EOF
fi
