#!/usr/bin/env bash
# Helpers to drive the app on the emulator by visible text (uiautomator), for the foreground-service demo video.
OUT=${OUT:-/tmp/fgs}; mkdir -p "$OUT"
dump() { adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1; adb pull /sdcard/ui.xml "$OUT/ui_$1.xml" >/dev/null 2>&1; }
shot() { adb exec-out screencap -p > "$OUT/$1.png"; }
# tap_text <substring> : taps the center of the first element whose text/content-desc contains the substring
tap_text() {
  adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1; adb pull /sdcard/ui.xml "$OUT/cur.xml" >/dev/null 2>&1
  python3 - "$1" "$OUT/cur.xml" > "$OUT/xy.txt" <<'PY'
import sys,re,xml.etree.ElementTree as ET
t=sys.argv[1]; root=ET.parse(sys.argv[2]).getroot()
for n in root.iter('node'):
    s=(n.get('text') or '')+' '+(n.get('content-desc') or '')
    if t in s:
        m=re.findall(r'\d+',n.get('bounds')); x=(int(m[0])+int(m[2]))//2; y=(int(m[1])+int(m[3]))//2
        print(x,y); break
PY
  if [ -s "$OUT/xy.txt" ]; then adb shell input tap $(cat "$OUT/xy.txt"); echo "tapped: $1"; return 0; else echo "NOT FOUND: $1"; return 1; fi
}
