#!/bin/sh
# Send one command to the running Lightroom plug-in and print its answer.
# usage: lrc_cmd.sh action=tone style=a group=time
D=~/LRCDF/plugin_work/cmd; N=c$(date +%s)$$
printf "%s\n" "$@" > "$D/$N.tmp" && mv "$D/$N.tmp" "$D/$N.cmd"
i=0; while [ ! -f "$D/$N.done" ] && [ $i -lt ${LRC_TIMEOUT:-180} ]; do sleep 1; i=$((i+1)); done
[ -f "$D/$N.done" ] && cat "$D/$N.done" || { echo timeout; exit 1; }
