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
for n in root.iter('node'):
    s=(n.get('text') or '')+' '+(n.get('content-desc') or '')
    if t in s and n.get('bounds'):
        m=re.findall(r'\d+',n.get('bounds')); print((int(m[0])+int(m[2]))//2,(int(m[1])+int(m[3]))//2); break
PY
  if [ -s "$OUT/xy.txt" ]; then adb shell input tap $(cat "$OUT/xy.txt"); log "tapped '$1' at $(cat "$OUT/xy.txt")"; return 0; fi
  log "NOT FOUND '$1'; visible: $(texts)"; return 1
}
