#!/usr/bin/env bash
#
# Remove PGS / VOBSUB subtitle tracks from Matroska files.
#
# Why: an image subtitle is a picture, not text. No client can render one, so
# Plex and Jellyfin must burn it into the video, which forces a full re-encode.
# Plex here is set to remux only and Jellyfin has no hardware encoder, so
# selecting one fails playback outright. Deleting the tracks removes the trap.
#
# On-screen text translation is protected. The script keeps an image track when
# it carries the forced flag, or is named forced/signs/songs, AND no text
# subtitle covers that language. It also refuses to leave a file with no
# subtitle at all. Use --strip-all to override the first rule, --force the
# second.
#
# Usage:
#   strip-image-subs.sh                       # dry run over every library root
#   strip-image-subs.sh --apply               # rewrite the whole library
#   strip-image-subs.sh "/data/movies/Some Film (2009)"
#   strip-image-subs.sh --apply "/mnt/hdd/shows/Some Show"
#   strip-image-subs.sh --apply /path/to/one.mkv
#   strip-image-subs.sh --install-deps       # install anything missing, then run
#
# Rewriting is a remux: no re-encode, so quality is untouched, but each file is
# written out again. It needs free space equal to the largest file it touches.

set -uo pipefail

APPLY=0; STRIP_ALL=0; FORCE=0; INSTALL_DEPS=0
ROOTS=()
for arg in "$@"; do
  case "$arg" in
    --apply)     APPLY=1 ;;
    --strip-all) STRIP_ALL=1 ;;
    --force)     FORCE=1 ;;
    --install-deps) INSTALL_DEPS=1 ;;
    -h|--help)   sed -n '3,26p' "$0"; exit 0 ;;
    -*)          echo "unknown option: $arg" >&2; exit 2 ;;
    *)           ROOTS+=("$arg") ;;
  esac
done
[ ${#ROOTS[@]} -eq 0 ] && ROOTS=(/data/movies /data/shows /mnt/hdd/movies /mnt/hdd/shows /mnt/hdd/videos)

for r in "${ROOTS[@]}"; do
  [ -e "$r" ] || { echo "no such path: $r" >&2; exit 2; }
done
# --- dependency check -------------------------------------------------------
# mkvmerge does the remux, jq reads its JSON, numfmt formats the freed bytes.
# Report every missing tool at once rather than one per run.
check_deps() {
  local missing_bins=() missing_pkgs=() bin pkg
  for pair in "mkvmerge:mkvtoolnix" "jq:jq" "numfmt:coreutils"; do
    bin=${pair%%:*}; pkg=${pair##*:}
    if ! command -v "$bin" >/dev/null 2>&1; then
      missing_bins+=("$bin")
      [[ " ${missing_pkgs[*]:-} " == *" $pkg "* ]] || missing_pkgs+=("$pkg")
    fi
  done

  [ ${#missing_bins[@]} -eq 0 ] && return 0

  echo "Missing required tool(s): ${missing_bins[*]}" >&2
  if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew is not on PATH. Install the packages another way: ${missing_pkgs[*]}" >&2
    exit 1
  fi
  if [ "$INSTALL_DEPS" -eq 1 ]; then
    echo "Installing: ${missing_pkgs[*]}" >&2
    brew install "${missing_pkgs[@]}" || exit 1
    for bin in "${missing_bins[@]}"; do
      command -v "$bin" >/dev/null 2>&1 || { echo "still missing after install: $bin" >&2; exit 1; }
    done
    echo "Dependencies installed." >&2
  else
    echo "Install them with:" >&2
    echo "    brew install ${missing_pkgs[*]}" >&2
    echo "Or re-run this script with --install-deps." >&2
    exit 1
  fi
}
check_deps

IMAGE_RE='S_HDMV/PGS|S_VOBSUB|S_DVBSUB|S_IMAGE'
SIGNS_RE='forced|signs|songs'

stripped=0; kept_signs=0; skipped=0; scanned=0; reclaimed=0

human() { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1}B"; }

while IFS= read -r -d '' f; do
  scanned=$((scanned+1))
  info=$(mkvmerge -J "$f" 2>/dev/null) || { echo "unreadable: $f" >&2; continue; }

  # Does this file have any image subtitle at all?
  n_img=$(echo "$info" | jq --arg re "$IMAGE_RE" '
    [.tracks[] | select(.type=="subtitles") | select(.properties.codec_id|test($re))] | length')
  [ "${n_img:-0}" -eq 0 ] && continue

  # Sidecar SRTs belonging to this file. The prefix is matched in the shell,
  # never handed to find -name: release names contain [ ], which find would
  # read as a glob character class and then match nothing.
  dir=$(dirname "$f"); base=$(basename "$f"); base=${base%.*}
  sidecars=()
  while IFS= read -r s; do
    case "$(basename "$s")" in "$base"*) sidecars+=("$s") ;; esac
  done < <(find "$dir" -maxdepth 2 -name '*.srt' 2>/dev/null)

  # Languages already covered by a text subtitle, embedded or sidecar.
  text_langs=$(echo "$info" | jq -r '
    .tracks[] | select(.type=="subtitles")
    | select(.properties.codec_id|test("S_TEXT|S_SSA|S_ASS"))
    | .properties.language // "und"' | sort -u)
  for s in ${sidecars[@]+"${sidecars[@]}"}; do
    case "$s" in
      *.eng.srt|*.eng.sdh.srt|*.en.srt|*.english.srt) text_langs+=$'\n'eng ;;
      *) text_langs+=$'\n'und ;;
    esac
  done
  text_langs=$(printf '%s\n' "$text_langs" | sort -u | grep -v '^$')

  # Decide each image track: keep only signs/forced with no text cover.
  keep_img_ids=(); drop_desc=(); keep_desc=()
  while IFS=$'\x1f' read -r id codec lang name forced; do
    [ -z "$id" ] && continue
    is_signs=0
    [ "$forced" = "true" ] && is_signs=1
    echo "$name" | grep -qiE "$SIGNS_RE" && is_signs=1
    covered=0
    echo "$text_langs" | grep -qx "$lang" && covered=1
    if [ "$STRIP_ALL" -eq 0 ] && [ "$is_signs" -eq 1 ] && [ "$covered" -eq 0 ]; then
      keep_img_ids+=("$id")
      keep_desc+=("id=$id $codec lang=$lang name=${name:--} (signs, no $lang text)")
    else
      drop_desc+=("id=$id $codec lang=$lang name=${name:--}")
    fi
  done < <(echo "$info" | jq -r --arg re "$IMAGE_RE" '
    .tracks[] | select(.type=="subtitles") | select(.properties.codec_id|test($re))
    | [(.id|tostring), .properties.codec_id, (.properties.language//"und"),
       (.properties.track_name//""), ((.properties.forced_track//false)|tostring)]
    | join("\u001f")')

  [ ${#drop_desc[@]} -eq 0 ] && continue

  # Subtitle tracks that survive: every text track, plus any kept image track.
  keep_ids=$(echo "$info" | jq -r '
    .tracks[] | select(.type=="subtitles")
    | select(.properties.codec_id|test("S_TEXT|S_SSA|S_ASS")) | .id')
  for k in "${keep_img_ids[@]:-}"; do [ -n "$k" ] && keep_ids+=$'\n'"$k"; done
  keep_ids=$(echo "$keep_ids" | grep -v '^$' | sort -n -u | paste -sd,)

  # Never leave a film with nothing to read.
  if [ -z "$keep_ids" ] && [ ${#sidecars[@]} -eq 0 ] && [ "$FORCE" -eq 0 ]; then
    echo "SKIP (would leave no subtitle at all): $f"
    skipped=$((skipped+1)); continue
  fi

  echo "$f"
  for d in "${drop_desc[@]}"; do echo "    drop  $d"; done
  for k in "${keep_desc[@]:-}"; do [ -n "$k" ] && echo "    KEEP  $k"; done
  [ ${#keep_desc[@]} -gt 0 ] && kept_signs=$((kept_signs+1))

  if [ "$APPLY" -eq 1 ]; then
    tmp="$f.stripping.mkv"
    if [ -n "$keep_ids" ]; then subargs=(--subtitle-tracks "$keep_ids"); else subargs=(--no-subtitles); fi
    before=$(stat -c %s "$f")
    if mkvmerge -q -o "$tmp" "${subargs[@]}" "$f" >/dev/null 2>&1 && [ -s "$tmp" ]; then
      # Verify the rewrite before replacing the original.
      if mkvmerge -J "$tmp" >/dev/null 2>&1; then
        chmod --reference="$f" "$tmp" 2>/dev/null
        mv -f "$tmp" "$f"
        after=$(stat -c %s "$f")
        reclaimed=$((reclaimed + before - after))
        echo "    -> stripped, freed $(human $((before-after)))"
        stripped=$((stripped+1))
      else
        rm -f "$tmp"; echo "    -> FAILED verify, original untouched" >&2
      fi
    else
      rm -f "$tmp"; echo "    -> FAILED remux, original untouched" >&2
    fi
  fi
done < <(find "${ROOTS[@]}" -type f -iname '*.mkv' -print0 2>/dev/null)

echo
echo "scanned $scanned mkv file(s)"
if [ "$APPLY" -eq 1 ]; then
  echo "stripped $stripped; kept signs on $kept_signs; skipped $skipped; freed $(human $reclaimed)"
else
  echo "dry run - add --apply to rewrite"
fi
