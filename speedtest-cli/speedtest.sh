#!/bin/sh
# One Ookla test, 30 days of history, and the summary the Glance widget reads.
set -eu

# Off-net du servers only; e&'s own servers are on-net and read ~3x high.
# See README.md.
#   69177 du Dubai, 1674 du Sharjah, 69176 du Hatta,
#   69182 du Ras Al Khaimah, 1692 du Abu Dhabi
SERVERS="69177 1674 69176 69182 1692"
KEEP_DAYS=30
HISTORY=/data/history.jsonl
SUMMARY=/out/summary.json

result=
for id in $(printf '%s\n' $SERVERS | shuf); do
    result=$(speedtest -f json --accept-license --accept-gdpr -s "$id" 2>/dev/null \
        | jq -c 'select(.type == "result")') || true
    [ -n "$result" ] && break
    echo "$(date -Iseconds) server $id failed" >&2
done
[ -n "$result" ] || { echo "$(date -Iseconds) all servers failed" >&2; exit 1; }

touch "$HISTORY"
{ cat "$HISTORY"; echo "$result"; } \
    | jq -c --argjson days "$KEEP_DAYS" 'select(.timestamp >= (now - $days * 86400 | todate))' \
    > "$HISTORY.tmp"
mv "$HISTORY.tmp" "$HISTORY"

jq -s '{
    latest: (last | {
        timestamp,
        ping: .ping.latency,
        download_bits: (.download.bandwidth * 8),
        upload_bits: (.upload.bandwidth * 8),
        server: "\(.server.name) \(.server.location)",
        url: .result.url
    }),
    average: {
        count: length,
        ping: (map(.ping.latency) | add / length),
        download_bits: (map(.download.bandwidth * 8) | add / length),
        upload_bits: (map(.upload.bandwidth * 8) | add / length)
    }
}' "$HISTORY" > "$SUMMARY.tmp"
mv "$SUMMARY.tmp" "$SUMMARY"

# crond runs as root; hand the files back to the owner of the host folders.
chown "$(stat -c %u:%g /data)" "$HISTORY"
chown "$(stat -c %u:%g /out)" "$SUMMARY"

echo "$(date -Iseconds) $(jq -r '.latest | "\(.download_bits / 1e6 | floor) down / \(.upload_bits / 1e6 | floor) up / \(.ping) ms via \(.server)"' "$SUMMARY")"
