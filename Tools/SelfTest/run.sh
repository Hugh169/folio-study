#!/bin/bash
# Runs Folio's sandboxed self-test (Debug builds only): a setup run that sorts,
# plans and studies with test files, then a restart run that reopens the same
# records and checks they were kept. The delete run, only when asked for,
# deletes those records as Settings › Delete All Data does and checks what's left.
#
#   Tools/SelfTest/run.sh <path to Folio.app> [both|setup|restart|delete]
#
# Before running:
# - Quit every other copy of Folio, and don't build or run `swift test` at the
#   same time. A run alongside them once stalled waiting on the on-device AI.
# - Make the test files once:
#     cd FolioKit && swift run folio-testset ../Tools/TestSet/samples.json ../TestSet/generated
#
# The self-test never asks macOS for permission: it skips Calendar, Reminders,
# notifications and the real keychain item. Reports are written to
# ~/Library/Containers/<bundle ID>/Data/SelfTest/report.json, report-restart.json
# and report-delete.json.
set -euo pipefail

app="${1:?usage: Tools/SelfTest/run.sh <path to Folio.app> [both|setup|restart|delete]}"
phase="${2:-both}"
repo="$(cd "$(dirname "$0")/../.." && pwd)"
generated="$repo/TestSet/generated"
binary="$app/Contents/MacOS/Folio"
limit=1200 # seconds allowed for each run

[[ -x "$binary" ]] || { echo "No Folio binary at $binary" >&2; exit 1; }
[[ -d "$generated" ]] || { echo "No test files in $generated. Make them first (see the top of this script)." >&2; exit 1; }
if pgrep -x Folio > /dev/null; then
    echo "Folio is running. Quit it first, so the self-test runs on its own." >&2
    exit 1
fi

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
container="$HOME/Library/Containers/$bundle_id"
st="$container/Data/SelfTest"

# Runs Folio with a time limit. Extra arguments are passed to Folio.
run_folio() {
    "$binary" -FolioSelfTest "$st" "$@" > /dev/null 2>&1 &
    local pid=$! waited=0
    while kill -0 "$pid" 2> /dev/null; do
        if (( waited >= limit )); then
            kill "$pid" 2> /dev/null || true
            echo "Stopped after $limit seconds without finishing." >&2
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
    wait "$pid" || true
    echo "Finished in $waited seconds."
}

# macOS makes the container the first time Folio runs. A restart run with no
# records does nothing but start up, so it's a safe way to make it.
if [[ ! -d "$container" ]]; then
    echo "Making Folio's container…"
    run_folio -FolioSelfTestPhase restart
fi

summarise() {
    python3 -I - "$1" << 'PY'
import json, sys
path = sys.argv[1]
try:
    report = json.load(open(path))
except (OSError, ValueError) as error:
    sys.exit(f"No report at {path}: {error}")
print(f"  phase at launch: {report.get('phaseAtLaunch')}, screen: {report.get('screenAtLaunch')}")
if "phaseAfterSetup" in report:
    print(f"  phase after setup: {report['phaseAfterSetup']}")
    print(f"  sorting took: {report.get('sortingSeconds')} s")
state = report.get("afterActions") or report.get("state") or {}
print(f"  recently sorted: {len(state.get('recentlySorted', []))}, waiting: {len(state.get('needsReview', []))}")
failed = [item["name"] for item in state.get("sorting", []) if item.get("status") == "failed"]
if failed:
    print(f"  failed to sort: {', '.join(failed)}")
for key in ("planner", "study", "timetable", "before", "after", "reopened"):
    if key in report:
        print(f"  {key}: {json.dumps(report[key], ensure_ascii=False)[:300]}")
PY
}

if [[ "$phase" == "both" || "$phase" == "setup" ]]; then
    echo "Preparing $st"
    mkdir -p "$st"
    for name in School Watched "Task sheets" "Moved School" Drop Arrivals Shortcut; do
        rm -rf "${st:?}/$name"
    done
    rm -f "${st:?}/report.json" "${st:?}/report-restart.json" "${st:?}/Self-test.foliobackup"
    mkdir -p "$st/Drop" "$st/Arrivals" "$st/Shortcut"

    drop=(
        "English/1984 - themes and context.pdf"
        "English/Act 2 notes.txt"
        "Physics/2021-hsc-physics.pdf"
        "Physics/Electromagnetism notes.docx"
        "Mathematics/2023-HSC-Mathematics-Advanced.pdf"
        "History/2023-hsc-modern-history-exam.pdf"
        "History/Holocaust research notes.docx"
        "History/IMG_7003.jpg"
        "Chemistry/AQA GCSE Chemistry Paper 1 Higher 2019.pdf"
        "_Unsorted/Cafe roster week 32.pdf"
        "_Unsorted/Guitar chord chart.txt"
    )
    for file in "${drop[@]}"; do
        cp "$generated/$file" "$st/Drop/"
    done
    cp "$generated/Physics/2021-hsc-physics.pdf" "$st/Drop/copy of physics paper.pdf"
    cp "$generated/Mathematics/AQA GCSE Maths Paper 2 Higher June 2019.pdf" "$st/Arrivals/"
    cp "$generated/Chemistry/New Recording 9.m4a" "$st/Arrivals/"
    cp "$generated/_Unsorted/receipt.pdf" "$st/Arrivals/Pizza order.pdf"
    cp "$generated/History/Lesson recording.mp4" "$st/Shortcut/"

    echo "Setup run…"
    run_folio
    summarise "$st/report.json"
fi

if [[ "$phase" == "both" || "$phase" == "restart" ]]; then
    echo "Restart run…"
    run_folio -FolioSelfTestPhase restart
    summarise "$st/report-restart.json"
fi

if [[ "$phase" == "delete" ]]; then
    echo "Delete run…"
    rm -f "${st:?}/report-delete.json"
    run_folio -FolioSelfTestPhase delete
    summarise "$st/report-delete.json"
fi
