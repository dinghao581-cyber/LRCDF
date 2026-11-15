#!/bin/bash
# Puts downloaded parts in place, or takes the last update back (the app's updater calls it; see
# packaging/make_update.py and app/Sources/LRCDF/Updater.swift).
# usage: update_install.sh install <staging dir> <app path> <pid to wait for> <root, normally ~/LRCDF>
#        update_install.sh rollback <app path> <pid to wait for> <root>
# Staging, already checked against the signed manifest by the app:
#   <id>/<path as under root>…     for the components code, models-own, models-third, python-mac
#   <part>.paths                   the paths the part owns, one per line (e.g. "project")
#   <part>.keep                    paths inside those that belong to another part and stay (e.g. "project/runs")
#   app/LRCDF.app                  the new app, if the app changed
#   components.json                the versions to record as installed (-> <root>/.components.json)
# What is replaced goes to <root>/.previous, so exactly one step back is possible.
set -e
ORDER="code models-own models-third python-mac"
aside() {       # aside <root> <keep list file> <holding dir>: move kept paths out of the way
    [ -f "$2" ] || return 0
    while IFS= read -r keep; do
        [ -n "$keep" ] && [ -e "$1/$keep" ] && { mkdir -p "$3/$(dirname "$keep")"; mv "$1/$keep" "$3/$keep"; }
    done < "$2"
    return 0
}
restore() {     # restore <root> <keep list file> <holding dir>: and back again
    [ -f "$2" ] || return 0
    while IFS= read -r keep; do
        [ -n "$keep" ] && [ -e "$3/$keep" ] && { mkdir -p "$1/$(dirname "$keep")"; rm -rf "$1/$keep"; mv "$3/$keep" "$1/$keep"; }
    done < "$2"
    rm -rf "$3"
    return 0
}
plugin() {      # the Lightroom plug-in is a copy of what is in the project
    local P="$1/project/plugin/LRCDFAuto.lrplugin"
    [ -d "$P" ] || return 0
    [ "$1" = "$HOME/LRCDF" ] || return 0        # a test installation elsewhere never touches the real plug-in
    local M="$HOME/Library/Application Support/Adobe/Lightroom/Modules"
    if [ -d "$HOME/Documents/LRCDFAuto.lrplugin" ]; then rsync -a --delete "$P" "$HOME/Documents/"
    elif [ -d "$M/LRCDFAuto.lrplugin" ]; then rsync -a --delete "$P" "$M/"; fi
}
MODE="$1"
if [ "$MODE" = install ]; then
    STAGE="$2"; APP="$3"; PID="$4"; ROOT="$5"; PREV="$ROOT/.previous"
    while kill -0 "$PID" 2>/dev/null; do sleep 0.3; done
    [ -e "$ROOT/project/.git" ] && { echo "a developer's checkout is never updated"; exit 3; }
    rm -rf "$PREV"; mkdir -p "$PREV"
    for part in $ORDER; do
        [ -f "$STAGE/$part.paths" ] || continue
        cp "$STAGE/$part.paths" "$PREV/"; [ -f "$STAGE/$part.keep" ] && cp "$STAGE/$part.keep" "$PREV/"
        while IFS= read -r path; do
            [ -n "$path" ] && [ -e "$STAGE/$part/$path" ] || continue
            aside "$ROOT" "$STAGE/$part.keep" "$PREV/hold"
            if [ -e "$ROOT/$path" ]; then mkdir -p "$PREV/$part/$(dirname "$path")"; mv "$ROOT/$path" "$PREV/$part/$path"; fi
            mkdir -p "$ROOT/$(dirname "$path")"; mv "$STAGE/$part/$path" "$ROOT/$path"
            restore "$ROOT" "$STAGE/$part.keep" "$PREV/hold"
        done < "$STAGE/$part.paths"
    done
    if [ -d "$STAGE/app/LRCDF.app" ]; then
        mkdir -p "$PREV/app"; mv "$APP" "$PREV/app/LRCDF.app"; mv "$STAGE/app/LRCDF.app" "$APP"
    fi
    [ -f "$ROOT/.components.json" ] && cp "$ROOT/.components.json" "$PREV/components.json"
    cp "$STAGE/components.json" "$ROOT/.components.json"
    xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
    plugin "$ROOT" || true      # never let the plug-in copy keep the app from coming back
    rm -rf "$STAGE"
    open "$APP"
elif [ "$MODE" = rollback ]; then
    APP="$2"; PID="$3"; ROOT="$4"; PREV="$ROOT/.previous"
    while kill -0 "$PID" 2>/dev/null; do sleep 0.3; done
    [ -f "$PREV/components.json" ] || { echo "nothing to go back to"; exit 4; }
    for part in python-mac models-third models-own code; do          # the other way round
        [ -f "$PREV/$part.paths" ] || continue
        while IFS= read -r path; do
            [ -n "$path" ] && [ -e "$PREV/$part/$path" ] || continue
            aside "$ROOT" "$PREV/$part.keep" "$PREV/hold"
            rm -rf "$ROOT/$path"; mkdir -p "$ROOT/$(dirname "$path")"; mv "$PREV/$part/$path" "$ROOT/$path"
            restore "$ROOT" "$PREV/$part.keep" "$PREV/hold"
        done < "$PREV/$part.paths"
    done
    if [ -d "$PREV/app/LRCDF.app" ]; then rm -rf "$APP"; mv "$PREV/app/LRCDF.app" "$APP"; fi
    cp "$PREV/components.json" "$ROOT/.components.json"
    rm -rf "$PREV"
    plugin "$ROOT" || true      # never let the plug-in copy keep the app from coming back
    open "$APP"
fi
