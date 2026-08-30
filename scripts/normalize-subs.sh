#!/usr/bin/env bash
#
# Make every subtitle in the library readable text in English or Unknown.
#
# Image subtitles (PGS, VOBSUB, DVBSUB) are pictures: a server must burn them
# into the video, which Plex here and Jellyfin cannot do. ASS/SSA tracks carry
# fonts and positions, so clients render them differently and some transcode.
# SRT plays on every client and never forces a transcode.
#
# THE CONTAINER NEVER CHANGES. Video and audio are copied, never re-encoded.
#
# Matroska files (mkvmerge rebuilds the subtitles):
#  - Drops every subtitle that is not English and not Unknown.
#  - Copies SRT tracks, converts ASS/SSA/WebVTT/mov_text to SRT.
#  - Reads image tracks with OCR and writes SRT, keeping the source timings.
#    OCR runs only when no text track covers the language, or the track is
#    forced.
#
# MP4 and MOV files (ffmpeg remuxes into the same container):
#  - Drops every subtitle that is not English and not Unknown.
#  - Keeps text tracks as they are. MP4 cannot hold SRT, and mov_text is
#    already text.
#  - Leaves an image track alone and reports it. Removing it could leave the
#    file with nothing to read.
#
# A file is either fully converted or left alone. It is never half done.
#
# Usage:
#   normalize-subs.sh                          # dry run over every library root
#   normalize-subs.sh --apply                  # rewrite the whole library
#   normalize-subs.sh "/data/movies/Some Film (2009)"
#   normalize-subs.sh --apply "/mnt/hdd/shows/Some Show"
#   normalize-subs.sh --apply /path/to/one.mkv
#   normalize-subs.sh --install-deps           # install anything missing
#
# Options:
#   --apply          rewrite the files (default is a dry run)
#   --mkv-only       skip MP4 and MOV entirely
#   --no-ocr         drop image tracks instead of reading them
#   --ocr-all        read every image track, even one a text track covers
#   --keep-foreign   keep subtitles in other languages too
#   --jobs N         OCR worker count (default: CPU count)
#   --install-deps   install missing tools with brew, then run
#
# Needs free space equal to the largest file it rewrites.

set -uo pipefail

APPLY=0; NO_OCR=0; OCR_ALL=0; KEEP_FOREIGN=0; INSTALL_DEPS=0; MKV_ONLY=0
JOBS=$(nproc 2>/dev/null || echo 4)
ROOTS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)        APPLY=1 ;;
    --mkv-only)     MKV_ONLY=1 ;;
    --no-ocr)       NO_OCR=1 ;;
    --ocr-all)      OCR_ALL=1 ;;
    --keep-foreign) KEEP_FOREIGN=1 ;;
    --jobs)         shift; JOBS=${1:-4} ;;
    --jobs=*)       JOBS=${1#*=} ;;
    --install-deps) INSTALL_DEPS=1 ;;
    -h|--help)      sed -n '3,45p' "$0"; exit 0 ;;
    -*)             echo "unknown option: $1" >&2; exit 2 ;;
    *)              ROOTS+=("$1") ;;
  esac
  shift
done

[ ${#ROOTS[@]} -eq 0 ] && ROOTS=(/data/movies /data/shows /data/videos /mnt/hdd/movies /mnt/hdd/shows /mnt/hdd/videos)
for r in "${ROOTS[@]}"; do
  [ -e "$r" ] || { echo "no such path: $r" >&2; exit 2; }
done

case "$JOBS" in ''|*[!0-9]*) echo "--jobs needs a number" >&2; exit 2 ;; esac
[ "$JOBS" -lt 1 ] && JOBS=1

# ---------------------------------------------------------------- dependencies

check_deps() {
  local missing_bins=() missing_pkgs=() bin pkg pairs
  pairs="mkvmerge:mkvtoolnix ffmpeg:ffmpeg ffprobe:ffmpeg jq:jq"
  [ "$NO_OCR" -eq 0 ] && pairs="$pairs tesseract:tesseract magick:imagemagick"

  for pair in $pairs; do
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

WORKROOT=$(mktemp -d "${TMPDIR:-/tmp}/normalize-subs.XXXXXX") || exit 1

# The remux writes beside the original, so the move is a rename. Ctrl-C must
# not leave the part file behind: Plex watches these folders and would scan it.
LIVE_TMP=""
cleanup() {
  rm -rf "$WORKROOT"
  [ -n "$LIVE_TMP" ] && rm -f "$LIVE_TMP"
  return 0
}
trap cleanup EXIT

# ------------------------------------------------------------------ classifier

IMAGE_CODECS='hdmv_pgs_subtitle|dvd_subtitle|dvb_subtitle|xsub'
TEXT_CODECS='subrip|ass|ssa|webvtt|mov_text|text|stl|subviewer|microdvd'
SIGNS_RE='forced|signs|songs'
# A track can say "und" and still name its real language in the title.
FOREIGN_RE='russ|ukrain|ital|span|castil|latino|french|francai|german|deutsch|dutch|portug|brasil|swed|norw|dansk|danish|finn|polsk|polish|czech|cesk|slovak|sloven|magyar|hungar|greek|turk|arab|hebrew|farsi|persian|hindi|tamil|telugu|thai|viet|indo|malay|korean|japan|chin|mandarin|cantonese|roman|bulgar|croat|serb|eesti|eston|latvi|lietuv|lithuan|catal'

# Prints english, unknown or other.
lang_class() {
  local lang=$1 name=$2
  case "${lang,,}" in
    eng|en|en-*|en_*) echo english; return ;;
    ''|und|unk|mis|zxx)
      if [ -n "$name" ] && echo "$name" | grep -qiE "$FOREIGN_RE"; then
        echo other
      else
        echo unknown
      fi
      return ;;
  esac
  echo other
}

ms2ts() {
  local ms=$1
  printf '%02d:%02d:%02d,%03d' $((ms/3600000)) $((ms/60000%60)) $((ms/1000%60)) $((ms%1000))
}

# ------------------------------------------------------------------- SRT tidy

# ffmpeg wraps ASS cues in <font ...> and adds <b> for a bold style. Both are
# noise. Bold only goes when it covers the whole track, so emphasis survives.
tidy_srt() {
  local file=$1 total bold strip_bold=0
  total=$(grep -c ' --> ' "$file")
  [ "${total:-0}" -eq 0 ] && return 1
  bold=$(grep -c '<b>' "$file")
  [ "$bold" -gt $((total * 9 / 10)) ] && strip_bold=1

  awk -v strip_bold="$strip_bold" '
    BEGIN { RS = ""; FS = "\n"; n = 0 }
    {
      timing = ""
      text = ""
      for (i = 1; i <= NF; i++) {
        if (timing == "") { if ($i ~ / --> /) timing = $i; continue }
        text = text (text == "" ? "" : "\n") $i
      }
      if (timing == "") next

      gsub(/<[Ff][Oo][Nn][Tt][^>]*>/, "", text)
      gsub(/<\/[Ff][Oo][Nn][Tt]>/, "", text)
      gsub(/\{[^}]*\}/, "", text)          # leftover ASS override tags
      gsub(/\\[Nnh]/, " ", text)
      if (strip_bold) gsub(/<\/?[Bb]>/, "", text)
      gsub(/[ \t]+\n/, "\n", text)
      gsub(/\n[ \t]+/, "\n", text)
      gsub(/^[ \t\n]+/, "", text)
      gsub(/[ \t\n]+$/, "", text)

      if (text !~ /[^[:space:]]/) next
      n++
      printf "%d\n%s\n%s\n\n", n, timing, text
    }
  ' "$file" > "$file.tidy" && mv -f "$file.tidy" "$file"
  [ -s "$file" ]
}

# -------------------------------------------------------------------- extract

# Pull every wanted text track out as SRT in one pass: ffmpeg demuxes the
# source once however many outputs it writes.
# Takes the work directory and a list of "index:codec"; writes 0.srt, 1.srt, ...
extract_text_tracks() {
  local mkv=$1 work=$2
  shift 2
  local args=() spec idx codec n=0

  for spec in "$@"; do
    idx=${spec%%:*}; codec=${spec#*:}
    if [ "$codec" = "subrip" ]; then
      args+=(-map "0:$idx" -c:s copy -f srt "$work/$n.srt")
    else
      args+=(-map "0:$idx" -c:s srt -f srt "$work/$n.srt")
    fi
    n=$((n+1))
  done
  [ "$n" -eq 0 ] && return 0

  ffmpeg -nostdin -v error -y -i "$mkv" "${args[@]}" 2>/dev/null || return 1

  n=0
  for spec in "$@"; do
    codec=${spec#*:}
    [ -s "$work/$n.srt" ] || return 1
    if [ "$codec" != "subrip" ]; then
      tidy_srt "$work/$n.srt" || return 1
    fi
    n=$((n+1))
  done
  return 0
}

# ------------------------------------------------------------------------ OCR

# sub2video turns the bitmap stream into one frame per cue and a blank frame
# when it clears. settb=1/1000 with -frame_pts names each PNG after its
# millisecond timestamp, so the timings come from the source and cannot drift.
# gray flattens the cue onto its background; negate gives tesseract black on
# white.
ocr_track() {
  local mkv=$1 idx=$2 out=$3
  local work="$WORKROOT/ocr"
  rm -rf "$work"; mkdir -p "$work" || return 1

  if ! ffmpeg -nostdin -v error -y -i "$mkv" \
        -filter_complex "[0:$idx]format=gray,negate,settb=1/1000[v]" \
        -map "[v]" -fps_mode passthrough -frame_pts 1 "$work/%d.png" 2>/dev/null; then
    rm -rf "$work"; return 1
  fi

  local pts_file="$work/pts.list"
  find "$work" -maxdepth 1 -name '*.png' -printf '%f\n' \
    | sed 's/\.png$//' | grep -E '^[0-9]+$' | sort -n > "$pts_file"
  [ -s "$pts_file" ] || { rm -rf "$work"; return 1; }

  # Every blank frame is byte-identical, so the smallest size marks them.
  local blank
  blank=$(while read -r p; do stat -c %s "$work/$p.png"; done < "$pts_file" | sort -n | head -1)

  local work_file="$work/work.list"
  while read -r p; do
    [ "$(stat -c %s "$work/$p.png")" -gt "$blank" ] && echo "$work/$p.png"
  done < "$pts_file" > "$work_file"

  if [ -s "$work_file" ]; then
    # -trim is what makes OCR fast: tesseract scans the whole canvas otherwise.
    # OMP_THREAD_LIMIT=1 stops its OpenMP pool from oversubscribing the CPU,
    # which costs 50x when workers run in parallel.
    xargs -a "$work_file" -P "$JOBS" -I{} sh -c '
      magick "$1" -trim +repage -bordercolor white -border 20 "$1.t.png" 2>/dev/null || exit 0
      OMP_THREAD_LIMIT=1 tesseract "$1.t.png" "$1" --psm 6 >/dev/null 2>&1
    ' _ {} 2>/dev/null
  fi

  local n=0 cur end text i
  local -a pts=()
  mapfile -t pts < "$pts_file"
  : > "$out"
  for i in "${!pts[@]}"; do
    cur=${pts[i]}
    [ -f "$work/$cur.png.txt" ] || continue
    text=$(sed 's/[[:space:]]\+$//' "$work/$cur.png.txt" | sed 's/  \+/ /g' | awk 'NF')
    [ -z "$text" ] && continue
    end=${pts[i+1]:-}
    { [ -z "$end" ] || [ "$end" -le "$cur" ]; } && end=$((cur + 3000))
    n=$((n+1))
    printf '%d\n%s --> %s\n%s\n\n' "$n" "$(ms2ts "$cur")" "$(ms2ts "$end")" "$text" >> "$out"
  done

  rm -rf "$work"
  [ "$n" -gt 0 ]
}

# ----------------------------------------------------------------------- main

human() { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1}B"; }

SEP=$'\037'
converted=0; unchanged=0; failed=0; scanned=0; ocr_tracks=0; reclaimed=0; warned=0
mkv_seen=0; other_seen=0

if [ "$MKV_ONLY" -eq 1 ]; then
  find_types=(-iname '*.mkv')
else
  find_types=(\( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.m4v' -o -iname '*.mov' \))
fi

# Read the file list on fd 3, never on stdin. ffmpeg reads stdin and eats one
# byte of the list per call, which silently skips later files.
while IFS= read -r -d '' f <&3; do
  scanned=$((scanned+1))

  case "${f,,}" in
    *.mkv)       container=mkv; muxfmt=matroska; mkv_seen=$((mkv_seen+1)) ;;
    *.mp4|*.m4v) container=mp4; muxfmt=mp4;      other_seen=$((other_seen+1)) ;;
    *.mov)       container=mov; muxfmt=mov;      other_seen=$((other_seen+1)) ;;
    *)           continue ;;
  esac

  info=$(ffprobe -v error -show_entries \
      'stream=index,codec_type,codec_name:stream_tags=language,title:stream_disposition=default,forced,hearing_impaired' \
      -of json "$f" 2>/dev/null) || { echo "unreadable: $f" >&2; failed=$((failed+1)); continue; }

  subs=$(echo "$info" | jq -r '
    .streams[] | select(.codec_type=="subtitle")
    | [(.index|tostring), .codec_name,
       (.tags.language // ""), (.tags.title // ""),
       ((.disposition.default//0)|tostring),
       ((.disposition.forced//0)|tostring),
       ((.disposition.hearing_impaired//0)|tostring)]
    | join("\u001f")')
  [ -z "$subs" ] && { unchanged=$((unchanged+1)); continue; }

  # Pass one: sort the tracks, and note which classes a text track covers.
  keep_idx=(); keep_codec=(); keep_lang=(); keep_name=()
  keep_def=(); keep_forced=(); keep_hi=()
  img_idx=(); img_codec=(); img_lang=(); img_name=()
  img_def=(); img_forced=(); img_hi=(); img_signs=()
  drop_desc=(); drop_idx=(); note_desc=()
  text_cover=""

  while IFS="$SEP" read -r idx codec lang name def forced hi; do
    [ -z "$idx" ] && continue
    class=$(lang_class "$lang" "$name")
    if [ "$class" = "other" ] && [ "$KEEP_FOREIGN" -eq 0 ]; then
      drop_desc+=("id=$idx $codec lang=${lang:-und} name=${name:--} (foreign)")
      drop_idx+=("$idx")
      continue
    fi
    if echo "$codec" | grep -qE "^($TEXT_CODECS)$"; then
      keep_idx+=("$idx");   keep_codec+=("$codec")
      keep_lang+=("$lang"); keep_name+=("$name")
      keep_def+=("$def");   keep_forced+=("$forced"); keep_hi+=("$hi")
      # A forced track holds signs only, so it covers nothing on its own.
      [ "$forced" = "1" ] || text_cover="$text_cover $class"
    elif echo "$codec" | grep -qE "^($IMAGE_CODECS)$"; then
      if [ "$container" = "mkv" ]; then
        signs=0
        [ "$forced" = "1" ] && signs=1
        echo "$name" | grep -qiE "$SIGNS_RE" && signs=1
        img_idx+=("$idx");   img_codec+=("$codec")
        img_lang+=("$lang"); img_name+=("$name")
        img_def+=("$def");   img_forced+=("$forced"); img_hi+=("$hi")
        img_signs+=("$signs")
      else
        # An SRT cannot go into MP4, and removing this could leave nothing.
        note_desc+=("id=$idx $codec lang=${lang:-und} name=${name:--} (image sub, left as is)")
      fi
    elif [ "$container" = "mkv" ]; then
      drop_desc+=("id=$idx $codec lang=${lang:-und} name=${name:--} (unsupported)")
    else
      note_desc+=("id=$idx $codec lang=${lang:-und} name=${name:--} (unsupported, left as is)")
    fi
  done <<< "$subs"

  # Pass two: OCR is slow and lossy, so it runs only when nothing readable
  # already covers that language.
  ocr_idx=(); ocr_lang=(); ocr_name=(); ocr_def=(); ocr_forced=(); ocr_hi=()
  for i in ${img_idx[@]+"${!img_idx[@]}"}; do
    class=$(lang_class "${img_lang[i]}" "${img_name[i]}")
    covered=0
    [[ " $text_cover " == *" $class "* ]] && covered=1
    if [ "$NO_OCR" -eq 1 ]; then
      drop_desc+=("id=${img_idx[i]} ${img_codec[i]} lang=${img_lang[i]:-und} name=${img_name[i]:--} (--no-ocr)")
    elif [ "$OCR_ALL" -eq 1 ] || [ "$covered" -eq 0 ] || [ "${img_signs[i]}" -eq 1 ]; then
      ocr_idx+=("${img_idx[i]}");       ocr_lang+=("${img_lang[i]}")
      ocr_name+=("${img_name[i]}");     ocr_def+=("${img_def[i]}")
      ocr_forced+=("${img_forced[i]}"); ocr_hi+=("${img_hi[i]}")
    else
      drop_desc+=("id=${img_idx[i]} ${img_codec[i]} lang=${img_lang[i]:-und} name=${img_name[i]:--} (a text track covers $class)")
    fi
  done

  needs_work=0
  if [ "$container" = "mkv" ]; then
    # Nothing to drop and every survivor is already SRT: leave the file alone.
    [ ${#drop_desc[@]} -gt 0 ] && needs_work=1
    [ ${#ocr_idx[@]} -gt 0 ] && needs_work=1
    for i in ${keep_idx[@]+"${!keep_idx[@]}"}; do
      [ "${keep_codec[i]}" = "subrip" ] || needs_work=1
    done
  else
    # MP4 and MOV: removing a foreign track is the only safe change.
    [ ${#drop_idx[@]} -gt 0 ] && needs_work=1
  fi
  if [ "$needs_work" -eq 0 ]; then unchanged=$((unchanged+1)); continue; fi

  echo "$f"
  for i in ${keep_idx[@]+"${!keep_idx[@]}"}; do
    if [ "$container" != "mkv" ] || [ "${keep_codec[i]}" = "subrip" ]; then
      echo "    keep  id=${keep_idx[i]} ${keep_codec[i]} lang=${keep_lang[i]:-und} name=${keep_name[i]:--}"
    else
      echo "    conv  id=${keep_idx[i]} ${keep_codec[i]} -> srt lang=${keep_lang[i]:-und} name=${keep_name[i]:--}"
    fi
  done
  for i in ${ocr_idx[@]+"${!ocr_idx[@]}"}; do
    echo "    OCR   id=${ocr_idx[i]} -> srt lang=${ocr_lang[i]:-und} name=${ocr_name[i]:--}"
  done
  for d in ${drop_desc[@]+"${drop_desc[@]}"}; do echo "    drop  $d"; done
  for d in ${note_desc[@]+"${note_desc[@]}"}; do echo "    note  $d"; done

  [ "$APPLY" -eq 1 ] || continue

  # -------------------------------------------------------------- rewrite

  if [ "$container" != "mkv" ]; then
    # Remux into the same container, dropping only the foreign streams.
    tmp="$f.normalizing.tmp"
    LIVE_TMP="$tmp"
    before=$(stat -c %s "$f")
    mp4args=(-map 0)
    for d in ${drop_idx[@]+"${drop_idx[@]}"}; do mp4args+=(-map "-0:$d"); done
    ferr="$WORKROOT/ffmpeg.err"
    if ffmpeg -nostdin -v error -y -i "$f" "${mp4args[@]}" -c copy -f "$muxfmt" "$tmp" 2>"$ferr" \
       && [ -s "$tmp" ] && ffprobe -v error -show_entries format=format_name -of csv=p=0 "$tmp" >/dev/null 2>&1; then
      chmod --reference="$f" "$tmp" 2>/dev/null
      mv -f "$tmp" "$f"
      after=$(stat -c %s "$f")
      reclaimed=$((reclaimed + before - after))
      echo "    -> done, freed $(human $((before-after)))"
      converted=$((converted+1))
    else
      rm -f "$tmp"
      echo "    -> FAILED remux, original untouched" >&2
      head -3 "$ferr" 2>/dev/null | sed 's/^/       /' >&2
      failed=$((failed+1))
    fi
    LIVE_TMP=""
    continue
  fi

  work="$WORKROOT/file"
  rm -rf "$work"; mkdir -p "$work" || { failed=$((failed+1)); continue; }

  mux=(); ok=1; k=0

  # $1 srt  $2 language  $3 name  $4 default  $5 forced  $6 hearing impaired
  add_sub() {
    mux+=(--language "0:${2:-und}")
    [ -n "$3" ] && mux+=(--track-name "0:$3")
    mux+=(--default-track-flag "0:$([ "$4" = 1 ] && echo yes || echo no)")
    mux+=(--forced-display-flag "0:$([ "$5" = 1 ] && echo yes || echo no)")
    mux+=(--hearing-impaired-flag "0:$([ "$6" = 1 ] && echo yes || echo no)")
    mux+=(--sub-charset 0:UTF-8 "$1")
  }

  specs=()
  for i in ${keep_idx[@]+"${!keep_idx[@]}"}; do
    specs+=("${keep_idx[i]}:${keep_codec[i]}")
  done

  if [ ${#specs[@]} -gt 0 ]; then
    if extract_text_tracks "$f" "$work" "${specs[@]}"; then
      for i in ${keep_idx[@]+"${!keep_idx[@]}"}; do
        add_sub "$work/$k.srt" "${keep_lang[i]}" "${keep_name[i]}" \
                "${keep_def[i]}" "${keep_forced[i]}" "${keep_hi[i]}"
        k=$((k+1))
      done
    else
      echo "    -> FAILED to read the text tracks, original untouched" >&2
      ok=0
    fi
  fi

  if [ "$ok" -eq 1 ]; then
    for i in ${ocr_idx[@]+"${!ocr_idx[@]}"}; do
      srt="$work/$k.srt"; k=$((k+1))
      echo "    -> reading track ${ocr_idx[i]} with OCR, this takes a few minutes"
      if ocr_track "$f" "${ocr_idx[i]}" "$srt" && tidy_srt "$srt"; then
        ocr_tracks=$((ocr_tracks+1))
        echo "       $(grep -c ' --> ' "$srt") cue(s) read"
        add_sub "$srt" "${ocr_lang[i]}" "${ocr_name[i]}" \
                "${ocr_def[i]}" "${ocr_forced[i]}" "${ocr_hi[i]}"
      else
        echo "    -> FAILED OCR on track ${ocr_idx[i]}, original untouched" >&2
        ok=0; break
      fi
    done
  fi

  if [ "$ok" -eq 0 ]; then rm -rf "$work"; failed=$((failed+1)); continue; fi

  # Not .mkv: Plex watches library folders and would scan a part file.
  tmp="$f.normalizing.tmp"
  LIVE_TMP="$tmp"
  before=$(stat -c %s "$f")
  merr="$WORKROOT/mkvmerge.err"
  mkvmerge -q -o "$tmp" --no-subtitles "$f" ${mux[@]+"${mux[@]}"} >"$merr" 2>&1
  mrc=$?
  # mkvmerge exits 1 when it only printed warnings, so a real failure starts
  # at 2. A damaged source that mkvmerge resyncs past lands on 1.
  if [ "$mrc" -le 1 ] && [ -s "$tmp" ] && mkvmerge -J "$tmp" >/dev/null 2>&1; then
    if [ "$mrc" -eq 1 ]; then
      echo "    warn  source is damaged; mkvmerge resynced past it ($(grep -c '^Warning' "$merr") warning(s))"
      warned=$((warned+1))
    fi
    chmod --reference="$f" "$tmp" 2>/dev/null
    mv -f "$tmp" "$f"
    after=$(stat -c %s "$f")
    reclaimed=$((reclaimed + before - after))
    echo "    -> done, freed $(human $((before-after)))"
    converted=$((converted+1))
  else
    rm -f "$tmp"
    echo "    -> FAILED remux (mkvmerge rc=$mrc), original untouched" >&2
    grep -m3 -E '^(Error|Warning)' "$merr" 2>/dev/null | sed 's/^/       /' >&2
    failed=$((failed+1))
  fi
  LIVE_TMP=""
  rm -rf "$work"
done 3< <(find "${ROOTS[@]}" -type f "${find_types[@]}" -print0 2>/dev/null)

echo
echo "scanned $scanned file(s): $mkv_seen mkv, $other_seen mp4/mov; $unchanged already clean"
if [ "$APPLY" -eq 1 ]; then
  echo "converted $converted ($warned from a damaged source); OCR'd $ocr_tracks track(s); failed $failed; freed $(human $reclaimed)"
else
  echo "dry run - add --apply to rewrite"
fi
