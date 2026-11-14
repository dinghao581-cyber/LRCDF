#!/bin/sh
# Tone the given photos in several styles, export each, restore the photos, and build a contact sheet.
# usage: lrc_compare.sh <out dir> <ids,comma> <style> [style...]
cd ~/LRCDF/project; C=scripts/lrc_cmd.sh; W=$1; IDS=$2; shift 2; mkdir -p "$W"
$C action=save file="$W/saved.lua" ids=$IDS | tail -1
TAGS=""
for s in "$@"; do
  $C action=tone style=$s group=time ids=$IDS | tail -1
  $C action=export dir="$W" size=900 tag=$s ids=$IDS > /dev/null; TAGS="$TAGS,$s"
done
$C action=restore file="$W/saved.lua" ids=$IDS | tail -1
.venv/bin/python scripts/sheet.py "$W" "$W/sheet.jpg" "${TAGS#,}" "$IDS" ${CELL:-500}
