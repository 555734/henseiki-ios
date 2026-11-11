#!/usr/bin/env bash
# Records the real app on an x86_64 emulator: model download, microphone recording, voice registration, speech generation + playback.
source scripts/fgs_video/lib.sh
for i in 1 2 3; do adb push /tmp/sample.mp3 /sdcard/Download/my_voice.mp3 && break; sleep 5; done
adb install -r henseiki.apk >/dev/null
adb shell pm grant com.fusena.henseiki android.permission.RECORD_AUDIO
adb shell pm grant com.fusena.henseiki android.permission.POST_NOTIFICATIONS
adb shell settings put system show_touches 1
adb shell monkey -p com.fusena.henseiki -c android.intent.category.LAUNCHER 1; sleep 8

# 1. First-run model download (data sync foreground service)
rec_start 01-download
tap_text "同意して始める"; sleep 4
tap_text "モデルの準備を始める"; sleep 3
tap_text "始める"; sleep 8
shade 9 download
sleep 4; rec_stop 01-download
wait_text "あなたの声を登録します" 900 || { log "model not ready"; }
tap_text "声を登録する"; sleep 3

# 2. Microphone recording (microphone foreground service)
rec_start 02-microphone
tap_text "録音を始める"; sleep 5
dumpui mic; log "recording screen: $(texts | cut -c1-300)"; shot mic-screen
shade 9 microphone
tap_text "止め" || tap_text "停止" || tap_text "録音を終"; sleep 4
rec_stop 02-microphone

# 3. Voice registration from an audio file (processing foreground service)
rec_start 03-enroll
tap_text "音声ファイルを選ぶ"; sleep 3
tap_text "使う"; sleep 4
tap_text "Show roots"; sleep 2; tap_text "Downloads"; sleep 3
adb shell input tap 296 960; sleep 4
tap_text "この音声で声を登録する"; sleep 4
shade 8 enroll
wait_text "声を登録しました" 300 && sleep 3
rec_stop 03-enroll
tap_text "閉じる"; sleep 2

# 4. Speech generation (processing + playback foreground service)
rec_start 04-generate
tap_text "この声で読み上げる"; sleep 5
shade 9 generate
sleep 4; rec_stop 04-generate
wait_text "できた音声を聞く" 1200 || log "generation not finished: $(texts | cut -c1-300)"
rec_start 05-playback
tap_text "できた音声を聞く"; sleep 6
shot player; dumpui player; log "player: $(texts | cut -c1-300)"
shade 9 playback
sleep 6; rec_stop 05-playback
log "done"
