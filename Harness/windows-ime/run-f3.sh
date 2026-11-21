#!/usr/bin/env bash
# F3 Windows end-to-end rows of the Hangul follow design (V-W E1-E10), on top of run-k5.sh.
#
#   K5_BATCH=... K5_PASSWORD_FILE=... K5_MAC_DIR=... Harness/windows-ime/run-f3.sh <set> <engine> <iteration>
#
# <set>: local (E1-E7, Korean language list), e9 (windows, Korean list), e10 (the same rows as
# local through a share handle), e8 (en-US-only list), e8mask / e1mask (the follow toggle sent as
# the masked chord [E0 38, 1D] through a share handle, en-US-only / Korean list). The Mac input source is scripted with the
# harness's fake reader (KeyScript follow/src); the real one is never read or changed. Each row
# starts with an F7 tap so f3-judge.py can split the probe log; the judged rows go to
# <work>/results/<name>.judge.jsonl. The Mac side starts as ABC (en), the server as alphanumeric.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${K5_WORK:-${HOME}/.cache/k5-${K5_BATCH:?set K5_BATCH}}"
set_name="$1" engine="$2" iteration="$3"

PRE="click:100,40 wait:500 follow:en wait:1000"
E1="f7 src:ko wait:800 src:en wait:800"
E2a="f7 ctrldown wait:60 ctrlup wait:15 src:ko wait:800"
E2b="f7 ctrldown wait:60 srcq:en kd:_ wait:30 kd:_ wait:30 ku:_ wait:60 ctrlup wait:800"
E3a="f7 ctrldown wait:40 optdown wait:60 optup wait:20 ctrlup wait:15 src:ko wait:800"
E3b="f7 ctrldown wait:40 optdown wait:40 srcq:en kd:_ wait:30 ku:_ wait:40 optup wait:40 ctrlup wait:800"
E4="f7 roptdown wait:80 roptup wait:100 src:ko wait:800"
E5="f7 src:en wait:100 roptdown wait:80 roptup wait:800"
E6a="f7 src:us wait:400 src:en wait:400"
E6s="f7 src:ko wait:800"
E6b="f7 src:ko3 wait:400 src:ko wait:400"
E7="f7 blur wait:200 src:en wait:300 focus wait:1000"
E7s="f7 src:ko wait:800"

case "${set_name}" in
  local)
    labels=(E1 E2a E2b E3a E3b E4 E5 E6a E6s E6b E7 E7s)
    steps=(keys "${PRE} ${E1} ${E2a} ${E2b} ${E3a} ${E3b} ${E4} ${E5} ${E6a} ${E6s} ${E6b} ${E7} ${E7s} f7") ;;
  e10)
    labels=(E1 E4 E5 E6a E6s E6b E7 E7s)
    steps=(sharedKeys "${PRE} ${E1} ${E4} ${E5} ${E6a} ${E6s} ${E6b} ${E7} ${E7s} f7") ;;
  e9)
    labels=(E9a-tb1-flip E9b-window2 E9c-newwindow E9d-notepad E9e-tb1 E9f-notepad-flip E9g-tb1 E9h-window2)
    steps=(keys "${PRE} f7 src:ko wait:800 f7 click:1000,40 wait:800 f7 f8 wait:1500 f7 f9 wait:3000 click:200,400 wait:800 f7 click:100,40 wait:800 f7 click:200,400 wait:300 src:en wait:800 f7 click:100,40 wait:800 f7 click:1000,40 wait:800 f7") ;;
  e8)
    labels=(E8-E1 E8-notepad-open E8-notepad-flip E8-notepad-ropt)
    steps=(keys "${PRE} ${E1} f7 f9 wait:3000 click:200,400 wait:800 f7 src:ko wait:800 src:en wait:800 f7 ropt wait:500 f7") ;;
  e8mask)
    labels=(E8-E1 E8-notepad-open E8-notepad-flip)
    steps=(sharedKeys "mask ${PRE} ${E1} f7 f9 wait:3000 click:200,400 wait:800 f7 src:ko wait:800 src:en wait:800 f7") ;;
  e1mask)
    labels=(E1 E1-notepad-open E1-notepad-flip E1-type)
    steps=(sharedKeys "mask ${PRE} ${E1} f7 f9 wait:3000 click:200,400 wait:800 f7 src:ko wait:800 src:en wait:800 f7 click:100,40 wait:300 src:ko wait:800 t:rkskek wait:500 src:en wait:800 f7") ;;
  *) echo "unknown set ${set_name}" >&2; exit 2 ;;
esac

name="f3-${set_name}-${engine}-${iteration}"
"${HERE}/run-k5.sh" run "${name}" "${engine}" korean "${steps[@]}"
python3 "${HERE}/f3-judge.py" "${WORK}/results/${name}.windows.txt" "${labels[@]}" > "${WORK}/results/${name}.judge.jsonl"
cat "${WORK}/results/${name}.judge.jsonl"
