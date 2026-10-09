#!/bin/sh
# Live test session: you talk to Capipaste, Claude reads what it heard and how tidy changed it.
#   scripts/testenv.sh start    install a hooks build (logs heard/light/rewrite text); marks the start unless a session is open
#   scripts/testenv.sh report   log lines and takes (.txt + .m4a) since the mark
#   scripts/testenv.sh replay   re-run this session's recordings through the current build's speech + tidy
#   scripts/testenv.sh stop     reinstall the normal build (hooks builds let any process drive mic and screen)
set -e
cd "$(dirname "$0")/.."
log=~/Library/Logs/Capipaste.log
caps=~/Pictures/Capipaste
mark=build/testenv.mark
app=/Applications/Capipaste.app/Contents/MacOS/Capipaste

takes() { find "$caps" -maxdepth 1 -name 'Capipaste *' -newer "$mark" | sort; }

case "$1" in
start)
    scripts/install.sh hooks
    mkdir -p build && { [ -f "$mark" ] || touch "$mark"; }
    defaults read com.chordlini.capipaste keepRecordings 2>/dev/null | grep -qx 0 &&
        echo "!! Settings keep no recordings: replay needs them (Settings > Recordings)."
    echo "Test session since $(date -r "$mark" '+%H:%M:%S'). Talk to Capi, then run: scripts/testenv.sh report" ;;
report)
    [ -f "$mark" ] || { echo "no session: scripts/testenv.sh start"; exit 1; }
    since=$(date -u -r "$mark" '+%Y-%m-%dT%H:%M:%SZ')
    echo "== log since $since"
    awk -v s="$since" '$1 >= s' "$log"
    echo "== takes"
    takes | while IFS= read -r f; do
        case "$f" in *.txt) printf -- '--- %s\n%s\n' "$(basename "$f")" "$(cat "$f")" ;; *) echo "--- $(basename "$f")" ;; esac
    done ;;
replay)
    [ -f "$mark" ] || { echo "no session: scripts/testenv.sh start"; exit 1; }
    pkill -x Capipaste || true
    start=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    takes | grep '\.m4a$' | tr '\n' '\0' | xargs -0 "$app" -sttfile
    # Each transcript through tidy again, so a tidy change shows against the same words.
    awk -v s="$start" '$1 >= s && /sttfile: .* result=/' "$log" | sed -e 's/.* result=//' -e 's/ problem=[^ ]*$//' | while IFS= read -r t; do
        [ "$t" = "nil (failed)" ] || "$app" -tidy "$t"
    done
    open /Applications/Capipaste.app
    awk -v s="$start" '$1 >= s && /sttfile:|tidy/' "$log" ;;
stop)
    scripts/install.sh
    rm -f "$mark" ;;
*) sed -n '2,6p' "$0"; exit 1 ;;
esac
