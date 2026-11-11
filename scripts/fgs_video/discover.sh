#!/usr/bin/env bash
set -x
source scripts/fgs_video/lib.sh
APK=henseiki.apk
adb install -r "$APK"
adb shell pm grant com.fusena.henseiki android.permission.RECORD_AUDIO
adb shell pm grant com.fusena.henseiki android.permission.POST_NOTIFICATIONS
adb shell am start -n com.fusena.henseiki/com.voiceclone.app.MainActivity || adb shell monkey -p com.fusena.henseiki 1
sleep 6; shot 01-start; dump 01-start
tap_text "同意して始める"; sleep 4; shot 02-after-terms; dump 02-after-terms
for p in 声 学習 モデル 読む; do tap_text "$p"; sleep 2; shot "03-page-$p"; dump "03-page-$p"; done
adb shell dumpsys package com.fusena.henseiki | grep -i "foregroundServiceType\|ABI" | head
adb logcat -d | tail -80 > "$OUT/logcat.txt"
