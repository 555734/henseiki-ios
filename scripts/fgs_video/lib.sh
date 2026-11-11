#!/usr/bin/env bash
# Helpers to drive the app on the emulator by visible text (uiautomator), for the foreground-service demo video.
OUT=${OUT:-/tmp/fgs}; mkdir -p "$OUT"
log() { echo "[$(date +%T)] $*" | tee -a "$OUT/log.txt"; }
shot() { adb exec-out screencap -p > "$OUT/$1.png"; }
dumpui() { # dumpui <name> : retries until a hierarchy is captured
  for i in 1 2 3 4 5 6; do
    rm -f "$OUT/cur.xml"
    adb shell uiautomator dump /sdcard/ui.xml >"$OUT/dump_out.txt" 2>&1
    adb pull /sdcard/ui.xml "$OUT/cur.xml" >/dev/null 2>&1 && [ -s "$OUT/cur.xml" ] && { cp "$OUT/cur.xml" "$OUT/ui_$1.xml"; return 0; }
    sleep 2
  done; log "dump failed: $(cat "$OUT/dump_out.txt")"; return 1
}
texts() { python3 - "$OUT/cur.xml" <<'PY'
import sys,xml.etree.ElementTree as ET
r=ET.parse(sys.argv[1]).getroot()
print(' | '.join(sorted({(n.get('text') or n.get('content-desc') or '') for n in r.iter('node') if (n.get('text') or n.get('content-desc'))}))[:1500])
PY
}
# tap_text <substring> : taps the first element whose text/content-desc contains the substring
tap_text() {
  dumpui cur >/dev/null || return 1
  python3 - "$1" "$OUT/cur.xml" > "$OUT/xy.txt" <<'PY'
import sys,re,xml.etree.ElementTree as ET
t=sys.argv[1]; root=ET.parse(sys.argv[2]).getroot()
def center(n):
    m=re.findall(r'\d+',n.get('bounds')); return (int(m[0])+int(m[2]))//2,(int(m[1])+int(m[3]))//2
nodes=[n for n in root.iter('node') if n.get('bounds')]
exact=[n for n in nodes if t in ((n.get('text') or '').strip(), (n.get('content-desc') or '').strip())]
part=[n for n in nodes if t in (n.get('text') or '')+' '+(n.get('content-desc') or '') and len(n.get('text') or '')<40]
for n in exact+part:
    print(*center(n)); break
PY
  if [ -s "$OUT/xy.txt" ]; then adb shell input tap $(cat "$OUT/xy.txt"); log "tapped '$1' at $(cat "$OUT/xy.txt")"; return 0; fi
  log "NOT FOUND '$1'; visible: $(texts)"; return 1
}
prepare_model() { # accept terms, download the model, wait until the voice-registration screen appears
  tap_text "同意して始める"; sleep 4
  tap_text "モデルの準備を始める"; sleep 3
  tap_text "始める"; sleep 4
  adb shell cmd statusbar expand-notifications; sleep 2; shot "10-download-notification"
  adb shell cmd statusbar collapse; sleep 1
  for i in $(seq 1 40); do
    sleep 15; dumpui w
    grep -q "あなたの声を登録します" "$OUT/cur.xml" && { log "model ready after $((i*15))s"; return 0; }
  done; log "model not ready"; return 1
}
rec_start() { adb shell rm -f /sdcard/rec_$1.mp4; (adb shell screenrecord --time-limit 170 --bit-rate 4000000 /sdcard/rec_$1.mp4 >/dev/null 2>&1 &) ; sleep 2; log "recording $1"; }
rec_stop() { adb shell pkill -SIGINT screenrecord; sleep 4; adb pull /sdcard/rec_$1.mp4 "$OUT/$1.mp4" >/dev/null 2>&1; log "saved $1 ($(stat -c %s "$OUT/$1.mp4" 2>/dev/null) bytes)"; }
shade() { adb shell cmd statusbar expand-notifications; sleep "${1:-7}"; shot "shade-$2"; adb shell cmd statusbar collapse; sleep 2; }
wait_text() { # wait_text <text> <seconds> : polls until the text is on screen
  local end=$((SECONDS+$2)); while [ $SECONDS -lt $end ]; do dumpui w >/dev/null && grep -q "$1" "$OUT/cur.xml" && return 0; sleep 6; done; return 1; }
# tap_or <text> <x> <y> : tap by text when the UI tree is readable, otherwise by coordinates (busy screens block uiautomator)
tap_or() { tap_text "$1" >/dev/null 2>&1 || { adb shell input tap "$2" "$3"; log "tapped '$1' by coordinates $2,$3"; }; }
