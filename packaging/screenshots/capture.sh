#!/bin/zsh
# Takes the Mac App Store screenshots and the App Review screenshots of the folder permission flow.
#
#   packaging/screenshots/capture.sh            both sets
#   packaging/screenshots/capture.sh store      App Store screenshots only (no clicks needed)
#   packaging/screenshots/capture.sh review     App Review shots: you click Measure once when asked
#
# Output: build/screenshots/store/*.png (1440x900, no alpha) and build/screenshots/review/*.png.
# Uses a fake home folder (make_demo_home.py, about 2 GB of real disk) and the app's demo mode
# (FOLDERDRILL_DEMO), so nothing from your own folders or settings shows up or changes.
#
# Needs: Screen Recording permission for the app running this script (macOS asks on first use),
# Pillow (pip3 install Pillow), and Folder Drill not running.
set -euo pipefail
cd "${0:A:h}/../.."

WHICH="${1:-all}"
OUT="$PWD/build/screenshots"
DEMO="$PWD/build/demo/Home"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: ThisBrainAI LLC (MP7PDLDJ96)}"
HERE=packaging/screenshots

if pgrep -x FolderDrill >/dev/null; then
  echo "Quit Folder Drill first: the demo runs its own copy." >&2
  exit 1
fi
mkdir -p "$OUT/store" "$OUT/review"
swiftc -O "$HERE/windows.swift" -o "$OUT/windows"
[[ -d "$DEMO" ]] || python3 "$HERE/make_demo_home.py" >/dev/null

# build <dest.app> [SANDBOX=1]
build() {
  local dest=$1; shift
  env "$@" SIGN_IDENTITY="$IDENTITY" ./build.sh 2>&1 | tail -1
  rm -rf "$dest" && cp -R build/FolderDrill.app "$dest"
}

PID=""
launch() { # launch <app> <shot>
  FOLDERDRILL_DEMO="$DEMO" FOLDERDRILL_DEMO_SHOT=$2 "$1/Contents/MacOS/FolderDrill" -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &
  PID=$!
}
quit_app() {
  if [[ -n "$PID" ]]; then kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; fi
  PID=""
}
# zsh skips EXIT traps when errexit fires, so also quit on errors.
trap quit_app EXIT
TRAPZERR() { quit_app }
TRAPINT() { quit_app; exit 130 }

windows() { "$OUT/windows" "$PID"; }
count() { windows | wc -l | tr -d ' '; }
wait_for() { # wait_for <op> <n> [seconds]: until the window count is >= n (op ge) or < n (op lt)
  local i=0 limit=$(( ${3:-15} * 4 ))
  while (( i++ < limit )); do
    local c=$(count)
    if [[ $1 == ge && $c -ge $2 ]] || [[ $1 == lt && $c -lt $2 ]]; then return 0; fi
    sleep 0.25
  done
  return 1
}

# shoot <out.png> [compose options]: captures every window of the app, back to front, and composes.
shoot() {
  local out=$1; shift
  local layers=() n=0
  mkdir -p "$OUT/layers"
  # The main window (the largest) first, then the others (the open panel). Capturing a sheet that's
  # attached to the main window returns the main window with the sheet in it, so a capture the same
  # size as the main window's is already covered and is skipped.
  local main_size=""
  for line in "${(@f)$(windows | sort -k4,4nr -k5,5nr)}"; do
    local f=(${=line})
    local png="$OUT/layers/$n.png"
    screencapture -x -o -l"${f[1]}" "$png"
    local size=$(sips -g pixelWidth -g pixelHeight "$png" | awk 'NR > 1 { printf "%s ", $2 }')
    if [[ -z "$main_size" ]]; then
      main_size=$size
    elif [[ "$size" == "$main_size" ]]; then
      continue
    fi
    layers+=("$png@${f[2]},${f[3]}")
    n=$((n + 1))
  done
  python3 "$HERE/compose.py" "$out" "$@" "${layers[@]}"
  rm -rf "$OUT/layers"
}

store() {
  build "$OUT/FolderDrill-demo.app"
  local shot n=1
  for shot in home library downloads trash; do
    launch "$OUT/FolderDrill-demo.app" $shot
    wait_for ge 1
    sleep 4 # window sizing, scan of the demo home (~45,000 items), the trash sheet
    shoot "$OUT/store/$n-$shot.png" --size 1440x900
    quit_app
    n=$((n + 1))
  done
}

review() {
  build "$OUT/FolderDrill-sandboxed.app" SANDBOX=1
  echo "Wait: Folder Drill is opening. Don't click anything yet."
  launch "$OUT/FolderDrill-sandboxed.app" setup
  wait_for ge 1 || { echo "Folder Drill didn't open a window." >&2; exit 1; }
  sleep 1.5
  shoot "$OUT/review/1-folder-setup.png" --plain

  echo
  echo ">>> NOW: in Folder Drill, click \"Choose Your Home Folder…\"."
  echo "    The picker opens in the demo home folder. Don't change folders; just click Measure."
  wait_for ge 2 600 || { echo "No folder picker opened." >&2; exit 1; }
  sleep 1.5
  shoot "$OUT/review/2-choose-home-folder.png" --plain --redact-sidebar
  wait_for lt 2 600 || { echo "Timed out waiting for Measure." >&2; exit 1; }
  echo "    Got it."
  sleep 4
  shoot "$OUT/review/3-home-folder-granted.png" --plain
  quit_app
}

case $WHICH in
  store) store ;;
  review) review ;;
  all) store; review ;;
  *) echo "usage: $0 [store|review|all]" >&2; exit 2 ;;
esac
echo "Screenshots in $OUT/store and $OUT/review"
