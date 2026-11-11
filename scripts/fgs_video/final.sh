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
tap_or "同意して始める" 818 1639; sleep 4
tap_or "モデルの準備を始める" 540 1061; sleep 3
tap_or "始める" 891 1368; sleep 8
shade 9 download
sleep 4; rec_stop 01-download
wait_text "あなたの声を登録します" 900 || log "model not ready"
tap_or "声を登録する" 540 996; sleep 3

# 2. Microphone recording (microphone foreground service)
rec_start 02-microphone
tap_or "録音を始める" 540 2017; sleep 3
tap_or "使う" 894 1368; sleep 6
shot mic-screen
shade 9 microphone
adb shell input tap 540 625; sleep 5      # in-app "録音を保存して終了"
shot after-mic
tap_text "閉じる" >/dev/null 2>&1; sleep 2
rec_stop 02-microphone

# 3. Voice registration from an audio file (processing foreground service)
rec_start 03-enroll
tap_or "音声ファイルを選ぶ" 540 1017; sleep 3
tap_or "使う" 894 1368; sleep 4
tap_or "Show roots" 73 191; sleep 2; tap_or "Downloads" 441 642; sleep 3
adb shell input tap 296 960; sleep 4
shot picked
tap_or "この音声で声を登録する" 540 2269; sleep 4
shade 8 enroll
sleep 40; shot enrolled
rec_stop 03-enroll
tap_or "閉じる" 890 1368; sleep 3

# 4. Speech generation (processing + playback foreground service)
rec_start 04-generate
tap_or "この声で読み上げる" 540 1210; sleep 5
shade 9 generate
sleep 4; rec_stop 04-generate
for i in $(seq 1 40); do   # wait for the generated audio (up to ~25 min), a screenshot per minute for review
  sleep 35; shot "gen-wait-$i"; dumpui g >/dev/null 2>&1 && grep -q "できた音声を聞く" "$OUT/cur.xml" && break
done
log "after generation wait: $(texts 2>/dev/null | cut -c1-300)"
rec_start 05-playback
tap_or "できた音声を聞く" 540 1400; sleep 6
shot player; dumpui player; log "player: $(texts 2>/dev/null | cut -c1-300)"
shade 9 playback
sleep 6; rec_stop 05-playback
log "done"
