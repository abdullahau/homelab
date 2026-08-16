#!/usr/bin/env bash
#
# plex-versions.sh — pre-build compressed companion files for 4K sources so
# Plex can serve a smaller version instead of transcoding on the fly.
#
# WHY: this host is an i5-5287U (Broadwell / Iris 6100). Its iGPU has NO
# hardware decoder for 10-bit HEVC, which is what every 2160p file in the
# library is. So a live Plex transcode of a 4K title is software-decoded on
# 2 physical cores and lands somewhere around real time — i.e. it buffers.
# Encoding the smaller version ahead of time removes that path entirely.
#
# HOW PLEX PICKS: multiple video files inside a single movie folder are
# collapsed into one library item with several "Versions", and the client
# requests the most suitable one automatically (users can also override with
# "Play Version"). So the output is written NEXT TO the source, in the same
# folder — nothing is moved, renamed, or deleted.
#
# Encoding is done inside lscr.io/linuxserver/ffmpeg because the Homebrew
# ffmpeg on this host is built without VAAPI.
#
# Usage:
#   ./plex-versions.sh [-p 1080p|720p] [-n] FILE_OR_DIR [FILE_OR_DIR ...]
#
#   -p   target profile (default 1080p)
#   -n   dry run: print what would be encoded, touch nothing
#
# Examples:
#   ./plex-versions.sh "/mnt/hdd/movies/Oppenheimer (2023) [2160p] [4K] [BluRay] [5.1] [YTS.MX]"
#   ./plex-versions.sh -n /mnt/hdd/movies          # survey the whole library
#   ./plex-versions.sh -p 720p /data/movies

set -euo pipefail

IMAGE="lscr.io/linuxserver/ffmpeg:latest"
RENDER_NODE="/dev/dri/renderD128"
PROFILE="1080p"
DRY_RUN=0
FORCE=0

while getopts ":p:nf" opt; do
    case "$opt" in
        p) PROFILE="$OPTARG" ;;
        n) DRY_RUN=1 ;;
        f) FORCE=1 ;;
        *) echo "usage: $0 [-p 1080p|720p] [-n] [-f] FILE_OR_DIR..." >&2; exit 2 ;;
    esac
done
shift $((OPTIND - 1))
[ $# -gt 0 ] || { echo "usage: $0 [-p 1080p|720p] [-n] [-f] FILE_OR_DIR..." >&2; exit 2; }

case "$PROFILE" in
    # box (WxH)             avg     peak    buffer
    1080p) WIDTH=1920; HEIGHT=1080; BITRATE=5M; MAXRATE=7M; BUFSIZE=10M ;;
    720p)  WIDTH=1280; HEIGHT=720;  BITRATE=3M; MAXRATE=4M; BUFSIZE=6M  ;;
    *) echo "unknown profile: $PROFILE (expected 1080p or 720p)" >&2; exit 2 ;;
esac

# Fit INSIDE the box rather than scaling on height alone. Scope (2.39:1) masters
# are stored as e.g. 3840x1606, and "scale=-2:1080" would turn that into
# 2582x1080 — more pixels than 1920x1080 and, at 11016 macroblocks, over the
# 8192 limit of the H.264 level we advertise. Strict decoders reject that.
#
# min(iw)/min(ih) keeps this from UPSCALING: a 1080p source re-encoded for codec
# compatibility must stay 1080p, not be blown up to fill the box.
SCALE="scale=w='min(${WIDTH},iw)':h='min(${HEIGHT},ih)':force_original_aspect_ratio=decrease:force_divisible_by=2"

[ -e "$RENDER_NODE" ] || { echo "no render node at $RENDER_NODE" >&2; exit 1; }

probe() { # probe <file> <entries>
    ffprobe -v error -select_streams v:0 -show_entries "stream=$2" \
        -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null | head -1
}

encode_one() {
    local src="$1"
    local dir base out
    dir="$(dirname "$src")"
    base="$(basename "$src")"

    local height transfer codec pixfmt reason=""
    height="$(probe "$src" height)"
    [ -n "$height" ] || { echo "  ~ skip (not a video): $base"; return 0; }
    codec="$(probe "$src" codec_name)"
    pixfmt="$(probe "$src" pix_fmt)"

    # What actually breaks Direct Play, in order of how often it bites:
    #   - HEVC / AV1 / VC-1 / MPEG-2 video: unsupported on browsers, older smart
    #     TVs, Chromecast, older Fire TV. H.264 is the universal baseline.
    #   - >8-bit pixel formats: even where HEVC decodes, Main 10 often does not.
    #   - Anything larger than the target box: bandwidth and client decode limits.
    # A file that trips none of these already direct-plays; re-encoding it would
    # only lose quality, so it is skipped unless -f is given.
    case "$codec" in
        hevc|av1|vc1|mpeg2video|mpeg4|wmv3) reason="${codec} video" ;;
    esac
    case "$pixfmt" in
        *10le|*10be|*12le|*12be)
            reason="${reason:+$reason, }${pixfmt} (>8-bit)" ;;
    esac
    if [ "$height" -gt "$HEIGHT" ] || [ "$(probe "$src" width)" -gt "$WIDTH" ]; then
        reason="${reason:+$reason, }larger than ${PROFILE}"
    fi
    if [ -z "$reason" ] && [ "$FORCE" -eq 0 ]; then
        echo "  ~ skip (${codec} ${height}p already direct-plays): $base"
        return 0
    fi
    [ -n "$reason" ] || reason="forced"

    # "Movie.2023.2160p.x265.mkv" -> "Movie.2023.2160p.x265 - 1080p H.264.mkv".
    # The " - <label>" suffix is what Plex shows as the version name. The codec
    # is part of the label because a 1080p x265 source also gets a companion —
    # same resolution, different codec — and "1080p" alone would be ambiguous.
    out="$dir/${base%.*} - ${PROFILE} H.264.mkv"
    if [ -e "$out" ]; then
        echo "  = exists: $(basename "$out")"
        return 0
    fi

    # HDR sources need a tonemap on the way down to 8-bit SDR, otherwise the
    # result looks washed out and grey. zscale/tonemap is a software filter and
    # roughly halves throughput, so it is only inserted when actually needed.
    local vf tonemap_note=""
    transfer="$(probe "$src" color_transfer)"
    case "$transfer" in
        smpte2084|arib-std-b67)
            vf="zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,${SCALE},format=nv12,hwupload"
            tonemap_note=" [HDR -> SDR tonemap, slow]"
            ;;
        *)
            vf="${SCALE},format=nv12,hwupload"
            ;;
    esac

    echo "  + ${codec} ${height}p -> ${PROFILE} H.264 [${reason}]${tonemap_note}: $base"
    if [ "$DRY_RUN" -eq 1 ]; then return 0; fi

    # Encode to a .part file so an interrupted run never leaves a truncated
    # video sitting in the movie folder for Plex to scan in as a real version.
    local tmp="${out}.part"
    if docker run --rm \
        --device "$RENDER_NODE:$RENDER_NODE" \
        --user "$(id -u):$(id -g)" \
        --group-add "$(stat -c %g "$RENDER_NODE")" \
        -v "$dir":/work \
        --entrypoint /usr/local/bin/ffmpeg \
        "$IMAGE" \
        -hide_banner -loglevel warning -stats -y \
        -init_hw_device "vaapi=va:$RENDER_NODE" -filter_hw_device va \
        -i "/work/$base" \
        -map 0:v:0 -map 0:a -map "0:s?" \
        -vf "$vf" \
        -c:v h264_vaapi -rc_mode VBR \
        -b:v "$BITRATE" -maxrate "$MAXRATE" -bufsize "$BUFSIZE" \
        -profile:v high -level 41 \
        -c:a aac -b:a 192k -ac 2 \
        -c:s copy \
        -max_muxing_queue_size 4096 \
        -f matroska "/work/$(basename "$tmp")"
    then
        mv -- "$tmp" "$out"
        echo "  ✓ $(basename "$out") ($(du -h "$out" | cut -f1))"
    else
        rm -f -- "$tmp"
        echo "  ✗ FAILED: $base" >&2
        return 1
    fi
}

for target in "$@"; do
    if [ -f "$target" ]; then
        echo "$(dirname "$target")"
        encode_one "$target" || true
    elif [ -d "$target" ]; then
        echo "$target"
        # -print0/read -d '' so paths with spaces and brackets survive intact.
        # Companion files we made earlier are excluded from the input set.
        while IFS= read -r -d '' f; do
            case "$f" in
                *" - 1080p H.264.mkv"|*" - 720p H.264.mkv"|*.part) continue ;;
            esac
            encode_one "$f" || true
        done < <(find "$target" -type f \
            \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.m4v' \) -print0 | sort -z)
    else
        echo "no such file or directory: $target" >&2
    fi
done
