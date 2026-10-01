#!/usr/bin/env bash
# Build a zip holding ONLY the files Cloudflare should serve, arranged so
# the folder inside can be dragged straight into the dashboard uploader.
#
# The repository zip cannot be used for this: the dashboard uploader does
# not read .assetsignore, so it takes sql/, scripts/, docs/ and the rest —
# a 40-file site became a "104 total files" upload — and a wrangler.toml
# in the folder makes it warn that the project needs a build step.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=${1:-/home/claude/building-portal-cloudflare.zip}
WORK=$(mktemp -d); STAGE="$WORK/building-portal"; mkdir -p "$STAGE"

cd "$ROOT"
find . -type f \
  -not -path './node_modules/*' -not -path './.git/*' -not -path './.github/*' \
  -not -path './sql/*' -not -path './scripts/*' -not -path './docs/*' \
  -not -name '.assetsignore' -not -name '.gitignore' \
  -not -name 'package.json' -not -name 'package-lock.json' \
  -not -name 'wrangler.toml' -not -name 'README.md' \
  -not -name '*.log' -not -name '*.zip' \
  | sed 's|^\./||' | sort > "$WORK/filelist.txt"

while read -r f; do mkdir -p "$STAGE/$(dirname "$f")"; cp "$f" "$STAGE/$f"; done < "$WORK/filelist.txt"
rm -f "$OUT"; (cd "$WORK" && zip -qr "$OUT" building-portal)
echo "Wrote $OUT — $(wc -l < "$WORK/filelist.txt") files"
rm -rf "$WORK"
