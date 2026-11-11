#!/usr/bin/env bash
source scripts/fgs_video/lib.sh
sudo apt-get install -y espeak-ng ffmpeg >/dev/null 2>&1
espeak-ng -v ja -s 135 -w /tmp/sample.wav "こんにちは。これは、私の声をもとにスマートフォンの中だけで作った音声です。今日はとても良い天気で、散歩に出かけました。公園では子どもたちが楽しそうに遊んでいて、私も少し休むことにしました。"
ffmpeg -y -loglevel error -i /tmp/sample.wav -ar 44100 -ac 1 /tmp/sample44.wav
adb push /tmp/sample44.wav /sdcard/Download/my_voice.wav >/dev/null
adb install -r henseiki.apk >/dev/null
adb shell pm grant com.fusena.henseiki android.permission.RECORD_AUDIO
adb shell pm grant com.fusena.henseiki android.permission.POST_NOTIFICATIONS
adb shell monkey -p com.fusena.henseiki -c android.intent.category.LAUNCHER 1; sleep 8
prepare_model
tap_text "声を登録する"; sleep 3; shot 20-voice; dumpui 20; log "voice: $(texts)"
tap_text "音声ファイルを選ぶ"; sleep 3; shot 21-pick; dumpui 21; log "pick: $(texts)"
