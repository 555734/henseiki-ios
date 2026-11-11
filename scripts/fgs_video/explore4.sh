#!/usr/bin/env bash
source scripts/fgs_video/lib.sh
for i in 1 2 3; do adb push /tmp/sample44.wav /sdcard/Download/my_voice.wav && break; sleep 5; done; log "downloads dir: $(adb shell ls -la /sdcard/Download | tr "
" ";")"
adb shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file:///sdcard/Download/my_voice.wav >/dev/null
adb install -r henseiki.apk >/dev/null
adb shell pm grant com.fusena.henseiki android.permission.RECORD_AUDIO
adb shell pm grant com.fusena.henseiki android.permission.POST_NOTIFICATIONS
adb shell monkey -p com.fusena.henseiki -c android.intent.category.LAUNCHER 1; sleep 8
prepare_model
tap_text "声を登録する"; sleep 3
tap_text "音声ファイルを選ぶ"; sleep 3
tap_text "使う"; sleep 4; shot 30-picker; dumpui 30; log "picker: $(texts)"
tap_text "Show roots"; sleep 2; shot 30b-roots; dumpui 30b; log "roots: $(texts)"; tap_text "Downloads"; sleep 3; shot 30c-dl; dumpui 30c; log "downloads: $(texts)"
adb shell input tap 296 960; sleep 4; shot 31-picked; dumpui 31; log "picked: $(texts)"
grep -q "Files in Downloads" "$OUT/cur.xml" && { log "file not picked, abort"; exit 1; }; true
tap_text "この音声で声を登録する"; sleep 4; shot 32-enroll; dumpui 32; log "enroll: $(texts)"
adb shell cmd statusbar expand-notifications; sleep 2; shot 33-shade; adb shell cmd statusbar collapse
for i in $(seq 1 60); do sleep 20; dumpui e; log "enroll t=$((i*20)): $(texts | cut -c1-200)"; shot "34-enroll-$i"; adb shell dumpsys meminfo com.fusena.henseiki | grep "TOTAL PSS" >> "$OUT/mem.txt"; grep -q "登録しました\|登録済み\|声を登録し\|処理を停止" "$OUT/cur.xml" || break; done
adb logcat -d | grep -i "voiceclone\|henseiki\|onnx\|AndroidRuntime\|lowmemory\|lmkd" | tail -150 > "$OUT/app_logcat.txt"
shot 34-enrolled
tap_text "読"; sleep 3; shot 35-read; dumpui 35; log "read: $(texts)"
tap_text "この声で読み上げる"; sleep 5; shot 36-gen; dumpui 36; log "gen: $(texts)"
adb shell cmd statusbar expand-notifications; sleep 2; shot 37-shade-gen; adb shell cmd statusbar collapse
for i in $(seq 1 30); do sleep 10; shot "38-gen-$i"; dumpui g; log "gen t=$((i*10)): $(texts)"; grep -q "できた音声\|再生" "$OUT/cur.xml" && break; done
