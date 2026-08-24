#!/usr/bin/env bash
# Renders every *.template in the repo using values from the root .env.
# A directory with its own render.sh is skipped (e.g. hysteria/, which runs
# on the VPS and keeps a separate .env).
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

[ -f .env ] || { echo "missing .env" >&2; exit 1; }

# Parsed line by line, not sourced: some values contain spaces (BESZEL_KEY),
# which the shell would split into commands.
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    [ "${line#*=}" = "$line" ] && continue
    name="${line%%=*}"
    value="${line#*=}"
    export "$name=$value"
done < .env

rendered=0
while IFS= read -r template; do
    dir="$(dirname "$template")"
    [ "$dir" != "." ] && [ -f "$dir/render.sh" ] && continue

    out="${template%.template}"

    # Substitute only the vars this template actually names, so nothing else
    # in the file is touched.
    vars="$(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$template" | sort -u | tr '\n' ' ')"
    for v in $vars; do
        name="${v:2:${#v}-3}"
        [ -n "${!name:-}" ] || { echo "$template: $name not set in .env" >&2; exit 1; }
    done

    envsubst "$vars" < "$template" > "$out"
    chmod 600 "$out"
    echo "rendered $out"
    rendered=$((rendered + 1))
done < <(find . -name '*.template' -not -path './.git/*' 2>/dev/null | sort)

echo "$rendered file(s) rendered"
