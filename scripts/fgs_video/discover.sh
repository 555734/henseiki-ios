#!/usr/bin/env bash
source scripts/fgs_video/lib.sh
APK=henseiki.apk
adb install -r "$APK" | tee -a "$OUT/log.txt"
adb shell pm grant com.fusena.henseiki android.permission.RECORD_AUDIO
adb shell pm grant com.fusena.henseiki android.permission.POST_NOTIFICATIONS
adb shell monkey -p com.fusena.henseiki -c android.intent.category.LAUNCHER 1
sleep 8; shot 01-start; dumpui 01-start; log "start: $(texts)"
tap_text "同意して始める"; sleep 5; shot 02-after-terms; dumpui 02; log "after terms: $(texts)"
for p in 声 モデル 読; do tap_text "$p"; sleep 3; shot "03-page-$p"; dumpui "03-$p"; log "page $p: $(texts)"; done
tap_text "設定"; sleep 3; shot 04-settings; dumpui 04; log "settings: $(texts)"
