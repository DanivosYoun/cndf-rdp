#!/usr/bin/env bash
# C4 Windows re-measurement of the follow input design (W1-W4, W6), on top of run-k5.sh.
#
#   K5_BATCH=... K5_PASSWORD_FILE=... K5_MAC_DIR=... Harness/windows-ime/run-c4.sh <set> <engine> <iteration>
#
# The rows go through the product paths: the local sets drive RDPClientView (follow gate and the
# executor's hostIMETap), the shared set drives a share handle the way the share host does
# (imeTap). <set>: w3 (E3b and E2b variants, the last with an auto-repeat Space, Korean list; the design's first falsification
# point), w1 (en-US-only list: two follows and two vk 104 taps in the probe and in notepad),
# w2 (E1 with the masked tap and typing, Korean list), w4 (a flip under a held Shift, Korean
# list), w6 / w6s (recovery with right Option in notepad, local / share handle), w5 / w5e (the
# host commands the app's real viewer path produced, recorded as `x:` tokens in $K5_W5_DIR by a
# test in an app working copy, replayed through a share handle; Korean / en-US-only list). The Mac input
# source is scripted with the harness's fake reader; the real one is never read or changed. Each
# row starts with an F7 tap so f3-judge.py can split the probe log. The Mac side starts as ABC
# (en), the server as alphanumeric.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${K5_WORK:-${HOME}/.cache/k5-${K5_BATCH:?set K5_BATCH}}"
set_name="$1" engine="$2" iteration="$3"

PRE="click:100,40 wait:500 follow:en wait:1000"
NOTEPAD="f7 f9 wait:3000 click:200,400 wait:800"

case "${set_name}" in
  w3)
    labels=(W3-pre W3-E3b W3-E2b W3-E3b2 W3-E2b-rep)
    steps=(keys "${PRE} f7 src:ko wait:800
      f7 ctrldown wait:40 optdown wait:40 srcq:en kd:_ wait:30 ku:_ wait:40 optup wait:40 ctrlup wait:800
      f7 ctrldown wait:60 srcq:ko kd:_ wait:30 kd:_ wait:30 ku:_ wait:60 ctrlup wait:800
      f7 ctrldown wait:40 optdown wait:40 srcq:en kd:_ wait:30 ku:_ wait:40 optup wait:40 ctrlup wait:800
      f7 ctrldown wait:60 srcq:ko kd:_ wait:30 kr:_ wait:30 ku:_ wait:60 ctrlup wait:800 f7") ;;
  w1)
    labels=(W1-flip W1-k104 W1-notepad-open W1-np-flip W1-np-k104)
    steps=(keys "${PRE} f7 src:ko wait:800 src:en wait:800 f7 k104 wait:800 k104 wait:800
      ${NOTEPAD} f7 src:ko wait:800 src:en wait:800 f7 k104 wait:800 k104 wait:800 f7") ;;
  w2)
    labels=(W2-E1 W2-notepad-open W2-np-flip W2-type)
    steps=(keys "${PRE} f7 src:ko wait:800 src:en wait:800 ${NOTEPAD} f7 src:ko wait:800 src:en wait:800
      f7 click:100,40 wait:300 src:ko wait:800 t:rkskek wait:500 src:en wait:800 f7") ;;
  w4)
    labels=(W4-ko W4-en)
    steps=(keys "${PRE} f7 shiftdown wait:40 srcq:ko kd:r wait:30 ku:r wait:40 shiftup wait:800
      f7 shiftdown wait:40 srcq:en kd:r wait:30 ku:r wait:40 shiftup wait:800 f7") ;;
  w6|w6s)
    labels=(W6-A-ko W6-B-open W6-B-ropt W6-B-mac-en)
    op=keys; [[ "${set_name}" == w6s ]] && op=sharedKeys
    steps=("${op}" "${PRE} f7 src:ko wait:800 ${NOTEPAD} f7 ropt wait:800 f7 src:en wait:800 f7") ;;
  w5)
    labels=(W5-E1 W5-E4 W5-E5 W5-W3pre W5-W3 W5-CtrlSpace W5-RCmd-hold W5-RCmd-flip W5-W6-B-open W5-W6-B-ropt W5-W6-B-mac-en)
    steps=(sharedKeys "$(cat "${K5_W5_DIR:?set K5_W5_DIR}/w5.tokens")") ;;
  w5e)
    labels=(W5-E8-flip W5-E8-k104 W5-E8-notepad-open W5-E8-np-flip W5-E8-np-k104)
    steps=(sharedKeys "$(cat "${K5_W5_DIR:?set K5_W5_DIR}/w5e.tokens")") ;;
  *) echo "unknown set ${set_name}" >&2; exit 2 ;;
esac

# The scenario takes the script as one space-separated string.
steps[1]="$(tr -s ' \n' ' ' <<<"${steps[1]}")"; steps[1]="${steps[1]% }"
name="c4-${set_name}-${engine}-${iteration}"
"${HERE}/run-k5.sh" run "${name}" "${engine}" korean "${steps[@]}"
python3 "${HERE}/f3-judge.py" "${WORK}/results/${name}.windows.txt" "${labels[@]}" > "${WORK}/results/${name}.judge.jsonl"
cat "${WORK}/results/${name}.judge.jsonl"
