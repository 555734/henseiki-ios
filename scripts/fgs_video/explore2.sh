#!/usr/bin/env bash
source scripts/fgs_video/lib.sh
adb install -r henseiki.apk >/dev/null
adb shell pm grant com.fusena.henseiki android.permission.RECORD_AUDIO
adb shell pm grant com.fusena.henseiki android.permission.POST_NOTIFICATIONS
adb shell monkey -p com.fusena.henseiki -c android.intent.category.LAUNCHER 1; sleep 8
tap_text "同意して始める"; sleep 4
tap_text "モデルの準備を始める"; sleep 3
tap_text "始める"; sleep 3   # confirmation dialog (about 1.1 GB)
shot 10-after-start; dumpui 10; log "after start: $(texts)"
adb shell cmd statusbar expand-notifications; sleep 2; shot 11-shade
adb shell cmd statusbar collapse; sleep 1
for i in $(seq 1 24); do
  sleep 20; shot "20-wait-$i"; dumpui w; log "t=$((i*20))s: $(texts)"
  grep -q "声を登録" "$OUT/cur.xml" && ! grep -q "ダウンロード" "$OUT/cur.xml" && break
done
for p in 声 読; do tap_text "$p"; sleep 3; shot "30-$p"; dumpui "30-$p"; log "page $p: $(texts)"; done
