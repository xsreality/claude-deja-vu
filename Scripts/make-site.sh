#!/bin/bash
# Wrap site/index.html into docs/index.html, which is what GitHub Pages serves.
#
# site/index.html is the source of truth and is deliberately headless: it is
# published as an Artifact for review, and that host supplies its own doctype,
# charset and viewport. Pages does not, so this adds them, plus the link-preview
# tags a shared URL needs.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=site/index.html
OUT=docs/index.html
URL="https://xsreality.github.io/claude-deja-vu"

# Everything down to the closing </style> belongs in <head>; the rest is <body>.
SPLIT="$(grep -n '^</style>' "$SRC" | head -1 | cut -d: -f1)"
[ -n "$SPLIT" ] || { echo "no </style> found in $SRC"; exit 1; }

{
  echo '<!doctype html>'
  echo '<html lang="en">'
  echo '<head>'
  echo '<meta charset="utf-8">'
  echo '<meta name="viewport" content="width=device-width, initial-scale=1">'
  echo '<link rel="icon" href="icon.svg" type="image/svg+xml">'
  echo "<link rel=\"canonical\" href=\"$URL/\">"
  echo '<meta property="og:type" content="website">'
  echo '<meta property="og:title" content="Claude Deja Vu">'
  echo '<meta property="og:description" content="Find that conversation you already had. Every Claude Code session, searchable across every repo, in one Mac app.">'
  echo "<meta property=\"og:url\" content=\"$URL/\">"
  echo "<meta property=\"og:image\" content=\"$URL/app.png\">"
  echo '<meta name="twitter:card" content="summary_large_image">'
  echo '<style>html{background:#14100f}</style>'
  head -n "$SPLIT" "$SRC"
  echo '</head>'
  echo '<body>'
  tail -n "+$((SPLIT + 1))" "$SRC"
  echo '</body>'
  echo '</html>'
} > "$OUT"

cp Resources/icon.svg docs/icon.svg

echo "built $OUT ($(du -h "$OUT" | cut -f1))"
