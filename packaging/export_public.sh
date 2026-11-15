#!/bin/zsh
# A copy of the source that may be published: the committed files without history, without the internal notes
# (CLAUDE.md and docs/ hold private working details) and without weights (never committed anyway).
# usage: packaging/export_public.sh [output folder, default ~/LRCDF/dist/public]
set -e
cd "$(dirname "$0")/.."
OUT="${1:-$HOME/LRCDF/dist/public}"; rm -rf "$OUT"; mkdir -p "$OUT/LRCDF"
git archive HEAD | tar -x -C "$OUT/LRCDF"
rm -f "$OUT/LRCDF/CLAUDE.md"
rm -rf "$OUT/LRCDF/docs"        # working notes between sessions: private details
rm -rf "$OUT/LRCDF/scripts/win3090"
rm -rf "$OUT/LRCDF/packaging/windows_port"     # briefs for the helper on the PC: internal
echo "exported to $OUT/LRCDF"; (cd "$OUT/LRCDF" && find . -type f | wc -l)
