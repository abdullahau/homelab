#!/usr/bin/env bash
# Build a sideload .ipk that this LG TV can run.
#
# Two packages, two jobs.
#
# Stremio (the default), from spcljense/stremio-webos. The upstream release
# does not work on this TV. The script applies three mods:
#
#   Mod 1  Send all traffic to the host. This is the recommended path.
#          The host torrents. The TV only decodes.
#   Mod 2  Give the TV an ffmpeg it can run. The TV is 32-bit (armv7l).
#          Upstream ships arm64 binaries, which cannot execute.
#   Mod 3  Raise the TV's download speed caps. The bundled server limits
#          itself to 21 Mbps, which is too slow for 4K.
#
# Mod 1 is complete by default: the bundled server never starts, and both
# 127.0.0.1:8080 and 127.0.0.1:11470 reach the host. The TV cannot torrent,
# so no Server setting can be wrong.
#
# --dual applies only the first half of Mod 1. It repoints the proxy but
# leaves the bundled server running:
#     8080  -> the host        11470 -> the TV itself
# You then choose in the app, under Settings -> Server. Mod 3 applies in
# this mode, because the TV can now torrent. Read "The cost of --dual" in
# the README first. The TV path has real limits.
#
# Wrapper (--wrapper), from Balazsmi/Stremio-LG-TV. The fallback app. It
# runs as published. The repack only strips the author's .git directory,
# which is 308 KB of the 384 KB installed.
#
# Usage:
#   ./build-stremio.sh                    # Stremio, host only, pinned version
#   ./build-stremio.sh 1.2.0              # Stremio, another release
#   ./build-stremio.sh --install          # build, install, launch, verify
#   ./build-stremio.sh --install --no-launch   # install, do not open the app
#   ./build-stremio.sh --dual             # keep the TV server too
#   ./build-stremio.sh --wrapper          # the fallback wrapper
#
# Override the defaults with environment variables:
#   UPSTREAM_HOST=127.0.0.1 ./build-stremio.sh   # keep the server on the TV
#   DEVICE=myTV ./build-stremio.sh
set -euo pipefail

MODE="stremio"
VERSION=""
INSTALL=""
LAUNCH="yes"
HOST_ONLY="yes"

# Print the header comment, however long it grows.
usage() { sed -n '2,/^set -/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'; }

for arg in "$@"; do
    case "$arg" in
        --wrapper)   MODE="wrapper" ;;
        --install)   INSTALL="yes" ;;
        --no-launch) LAUNCH="no" ;;
        --dual)      HOST_ONLY="no" ;;
        -h|--help)   usage; exit 0 ;;
        -*)          echo "unknown flag: $arg" >&2; echo >&2; usage >&2; exit 2 ;;
        *)           VERSION="$arg" ;;
    esac
done

FFMPEG_VERSION="7.0.2"
FFMPEG_URL="https://johnvansickle.com/ffmpeg/releases/ffmpeg-${FFMPEG_VERSION}-armhf-static.tar.xz"
# Single-stream throughput to that host is erratic: 6 KB/s to 480 KB/s in
# samples minutes apart, and flows sometimes stall dead. So resume across
# attempts and let the checksum be the gate. The tarball is cached in build/.
FFMPEG_SHA256="7d41f558cb1f3395b313f8ceabed78b3731c79a0962abf405ebb5cd393e93991"
FFMPEG_BYTES="16150344"

# Mod 3. The bundled server ships a low-power profile: 2621440 soft and
# 3670016 hard, which is 21 and 29 Mbps. A 4K HDR file needs 25 to 100 Mbps,
# so it can never fill one. These values raise the ceiling.
#
# The TV's eth0 is 100 Mbit full duplex, and it carries swarm upload as well
# as download. So do not set these near 100 Mbps. Leave headroom.
TV_SOFT_LIMIT="${TV_SOFT_LIMIT:-6291456}"   # 50 Mbps
TV_HARD_LIMIT="${TV_HARD_LIMIT:-8388608}"   # 67 Mbps
TV_SOFT_WAS="2621440"
TV_HARD_WAS="3670016"

UPSTREAM_HOST="${UPSTREAM_HOST:-192.168.0.100}"
UPSTREAM_PORT="${UPSTREAM_PORT:-11470}"
DEVICE="${DEVICE:-Rehab-LG}"

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$HERE/build"

say() { printf '\n==> %s\n' "$1"; }
die() { printf '\nERROR: %s\n' "$1" >&2; exit 1; }
mbps() { echo "$(( $1 * 8 / 1000000 )) Mbps"; }

# True when the bundled server on the TV can run, so Mod 3 matters.
tv_can_serve() {
    [ "$HOST_ONLY" = "no" ] \
        || [ "$UPSTREAM_HOST" = "127.0.0.1" ] \
        || [ "$UPSTREAM_HOST" = "localhost" ]
}

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

    ##################################################################
    # Mod 1: send all traffic to the host
    ##################################################################
    if [ "$HOST_ONLY" = "yes" ]; then
        say "Mod 1: all traffic -> ${UPSTREAM_HOST}:${UPSTREAM_PORT}, TV cannot torrent"
    else
        say "Mod 1 (half): proxy -> ${UPSTREAM_HOST}:${UPSTREAM_PORT}, TV server kept on 11470"
    fi
    UPSTREAM_HOST="$UPSTREAM_HOST" UPSTREAM_PORT="$UPSTREAM_PORT" HOST_ONLY="$HOST_ONLY" \
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

// Upstream Stremio server. The host does the torrenting, not the TV.
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

# ---- second half: never let the TV serve ----------------------------
if os.environ.get("HOST_ONLY") != "yes":
    open(path, "w").write(s)
    print("    second half skipped: the bundled server keeps 11470")
    sys.exit(0)

# The core builds stream URLs from the "Server" setting, which defaults to
# 127.0.0.1:11470 -- the bundled server. A user who never edits that setting
# silently torrents on the TV. Worse, the host's /tracks/:url handler then
# fetches that URL itself, so the host joins the same swarm and background
# downloads the whole file it never serves.
#
# So when the upstream is remote: do not start the bundled server at all,
# and listen on 11470 ourselves, proxying to the upstream. Then both
# addresses reach the host, the TV cannot torrent, and /tracks resolves
# 127.0.0.1:11470 inside the host to the real Stremio server.
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
    sys.exit("the server.js boot block changed. Read launch.js and update Mod 1.")
s = s.replace(old_boot, new_boot, 1)

old_term = """    try { server.close(); } catch (_) {}
    process.exit(0);"""
new_term = """    try { server.close(); } catch (_) {}
    try { if (shadow) shadow.close(); } catch (_) {}
    process.exit(0);"""
if old_term not in s:
    sys.exit("the SIGTERM handler changed. Read launch.js and update Mod 1.")
s = s.replace(old_term, new_term, 1)

if s.count("shadow.listen(11470") != 1:
    sys.exit("the shadow listener did not apply cleanly")
print("    bundled server disabled; 11470 shadowed to the upstream")

open(path, "w").write(s)
PY

    ##################################################################
    # Mod 2: give the TV an ffmpeg it can run
    ##################################################################
    say "Fetching armhf ffmpeg ${FFMPEG_VERSION}"
    local tarball="$WORK/ffmpeg-${FFMPEG_VERSION}-armhf.tar.xz"
    verify_tarball() { echo "$FFMPEG_SHA256  $tarball" | sha256sum -c --status 2>/dev/null; }
    if verify_tarball; then
        echo "    cached, checksum matches"
    else
        # Resume across attempts rather than restarting. curl can exit 0 on
        # a truncated file here, so the checksum is the only real gate.
        # The floor aborts a dead flow only; a slow one still finishes.
        local got=0
        for attempt in 1 2 3 4 5; do
            curl -fL -C - --speed-limit 2000 --speed-time 60 --progress-bar \
                -o "$tarball" "$FFMPEG_URL" || true
            if verify_tarball; then got=1; break; fi
            local size
            size=$(wc -c < "$tarball" 2>/dev/null || echo 0)
            if [ "$size" -ge "$FFMPEG_BYTES" ]; then
                # Full length but wrong hash: the bytes are bad, not missing.
                echo "    attempt $attempt: complete but corrupt, starting over"
                rm -f "$tarball"
            else
                echo "    attempt $attempt: $size of $FFMPEG_BYTES bytes, resuming"
            fi
        done
        [ "$got" = 1 ] || die "ffmpeg download failed or did not match $FFMPEG_SHA256"
    fi
    local ff="$WORK/ff"
    rm -rf "$ff" && mkdir -p "$ff"
    tar xJ --strip-components=1 -f "$tarball" -C "$ff" \
        "ffmpeg-${FFMPEG_VERSION}-armhf-static/ffmpeg" \
        "ffmpeg-${FFMPEG_VERSION}-armhf-static/ffprobe"

    say "Mod 2: swapping ffmpeg for the armhf build"
    cp "$ff/ffmpeg" "$ff/ffprobe" "$SRC/$svc/bin/"
    chmod +x "$SRC/$svc/bin/ffmpeg" "$SRC/$svc/bin/ffprobe"
    local b
    for b in ffmpeg ffprobe; do
        file "$SRC/$svc/bin/$b" | grep -q "ELF 32-bit.*ARM" \
            || die "$b is not a 32-bit ARM binary. The TV cannot run it."
        printf '    %-8s %s\n' "$b" "$(file -b "$SRC/$svc/bin/$b" | cut -d, -f1-2)"
    done
    if ! tv_can_serve; then
        echo "    note: Mod 1 stops the bundled server, so nothing runs these."
        echo "          They cost about 35 MB of the TV's 800 MB free space."
    fi

    ##################################################################
    # Mod 3: raise the TV's download speed caps
    ##################################################################
    if tv_can_serve; then
        say "Mod 3: raising the TV's caps to $(mbps "$TV_SOFT_LIMIT") soft, $(mbps "$TV_HARD_LIMIT") hard"
        TV_SOFT_LIMIT="$TV_SOFT_LIMIT" TV_HARD_LIMIT="$TV_HARD_LIMIT" \
        TV_SOFT_WAS="$TV_SOFT_WAS" TV_HARD_WAS="$TV_HARD_WAS" \
        python3 - "$SRC/$svc/server.js" <<'PY'
import os, sys

path = sys.argv[1]
s = open(path, encoding="utf8", errors="surrogateescape").read()

pairs = [("btDownloadSpeedSoftLimit", os.environ["TV_SOFT_WAS"], os.environ["TV_SOFT_LIMIT"]),
         ("btDownloadSpeedHardLimit", os.environ["TV_HARD_WAS"], os.environ["TV_HARD_LIMIT"])]

for key, was, now in pairs:
    old = "%s:%s" % (key, was)
    n = s.count(old)
    if n != 1:
        sys.exit("expected 1 %r in server.js, found %d. The bundled server's "
                 "defaults moved; re-read them before you trust this." % (old, n))
    s = s.replace(old, "%s:%s" % (key, now), 1)
    print("    %s %s -> %s" % (key, was, now))

open(path, "w", encoding="utf8", errors="surrogateescape").write(s)
PY
    else
        say "Mod 3 skipped: Mod 1 stops the bundled server, so its caps never apply"
    fi

    say "Packaging"
    OUT="$HERE/${APP_ID}_${VERSION}_all.ipk"
    rm -f "$OUT"
    # --no-minify is not optional. ares-package minifies JavaScript by
    # default, which can undo the patches above.
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
    # Package into its own directory. ares-package names its output exactly
    # like the cached download, so building into build/ would overwrite the
    # .ipk we just fetched and force a needless re-download.
    local pkgdir="$WORK/pkg"
    rm -rf "$pkgdir" && mkdir -p "$pkgdir"
    # --no-minify keeps main.js byte-identical to upstream. Without it,
    # ares-package rewrites the back-button handler.
    ( cd "$WORK" && ares-package --no-minify "$staged" -o "$pkgdir" ) >/dev/null
    local built="$pkgdir/${APP_ID}_${VERSION}_all.ipk"
    [ -f "$built" ] || die "ares-package produced no $built"
    mv "$built" "$OUT"
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

    # Mod 3 changes the bundled server's DEFAULTS. A server-settings.json
    # left on the TV by an earlier run overrides them, so clear it.
    if [ "$MODE" = "stremio" ] && tv_can_serve; then
        local_settings="/media/developer/apps/usr/palm/services/${APP_ID}.server/server-settings.json"
        say "Clearing the TV's stale server-settings.json"
        if ssh -o BatchMode=yes -o ConnectTimeout=5 tv "rm -f $local_settings" 2>/dev/null; then
            echo "    removed. The server writes a fresh one with the new caps."
        else
            echo "    ssh needs the key passphrase, so do it by hand:"
            echo "      ssh tv rm -f $local_settings"
            echo "    Until you do, the old 21 Mbps caps stay in force."
        fi
    fi

    if [ "$LAUNCH" = "no" ]; then
        say "Not launching: --no-launch"
        echo "    The new code loads the next time you open the app."
    else
        ares-launch -d "$DEVICE" "$APP_ID"
    fi

    if [ "$MODE" = "stremio" ] && [ "$LAUNCH" = "yes" ]; then
        say "Checking which server answers"
        sleep 20
        # The servers only answer while the app runs, and ssh needs the key
        # passphrase. Load it once with ssh-add to let this run unattended.
        if ssh-add -l >/dev/null 2>&1 && ssh -o BatchMode=yes tv true 2>/dev/null; then
            for p in 8080 11470; do
                printf '    port %-6s -> ' "$p"
                ssh tv "wget -qO- -T10 http://127.0.0.1:$p/settings" 2>/dev/null \
                    | grep -o '"serverVersion":"[^"]*"\|"cacheRoot":"[^"]*"' | tr '\n' ' '
                echo
            done
            echo
            if [ "$HOST_ONLY" = "yes" ]; then
                echo "    Want: cacheRoot /config on BOTH ports."
            else
                echo "    Want: cacheRoot /config on 8080, /media/developer on 11470."
            fi
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
        cat <<EOF

The bundled server runs on the TV, and the TV torrents. Mod 3 raised its
caps to $(mbps "$TV_SOFT_LIMIT") soft and $(mbps "$TV_HARD_LIMIT") hard.
EOF
    elif [ "$HOST_ONLY" = "no" ]; then
        cat <<EOF

Two servers, and you choose:
  http://127.0.0.1:8080/   -> ${UPSTREAM_HOST}:${UPSTREAM_PORT} (the host)
  http://127.0.0.1:11470/  -> the TV itself

Set it in the app: Settings -> Server -> EDIT_URL.
The core DEFAULTS to 11470, so leaving it unset makes the TV torrent.

Two costs you accept with --dual:
  1. On 11470 the host joins every swarm you open, through its own
     /tracks handler, and downloads files it never serves.
  2. On 8080 the host resolves 127.0.0.1:8080 to whatever else runs on
     its port 8080, so track enumeration breaks.

Check which one is working during playback:

  curl -s http://${UPSTREAM_HOST}:${UPSTREAM_PORT}/stats.json | grep -o '"selections":\[[^]]*'
EOF
    else
        cat <<EOF

Both 127.0.0.1:8080 and 127.0.0.1:11470 now reach
${UPSTREAM_HOST}:${UPSTREAM_PORT}, so the TV cannot torrent.

Still set Settings -> Server -> EDIT_URL to:

  http://127.0.0.1:11470/

Playback works on either port, but /tracks and /opensubHash do not. They pass
the stream URL to the host, and on 8080 the host fetches its own port 8080 --
glance, not Stremio. You then lose audio-language matching and subtitle
hashing, and the player re-probes the stream.
EOF
    fi
fi
