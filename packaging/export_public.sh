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
rm -rf "$OUT/LRCDF/i18n"                       # translated documents: README ones out of date, not public until updated (user, 2026-11-15)
rm -f "$OUT/LRCDF/packaging/"Windows-Install.*.md       # translations of the Windows install notes: older wording, retranslated from the current one before they come back (user, 2026-11-16)
rm -rf "$OUT/LRCDF/app/windows/fonts"           # 17 MB font of the Windows app: not public until the user decides
rm -rf "$OUT/LRCDF/packaging/windows_port"     # briefs for the helper on the PC: internal
rm -f "$OUT/LRCDF/packaging/publish_source.sh"  # its safety scan lists private words: internal
# The website is not public until the user says so, and it goes live through its own launch plan, never through this export
rm -rf "$OUT/LRCDF/site" "$OUT/LRCDF/site_preview"
find "$OUT/LRCDF" -type d -name _candidates -prune -exec rm -rf {} +
if find "$OUT/LRCDF" -type d \( -name site -o -name site_preview -o -name _candidates \) | grep -q .; then echo "STOP: website files in the export"; exit 1; fi
echo "exported to $OUT/LRCDF"; (cd "$OUT/LRCDF" && find . -type f | wc -l)
