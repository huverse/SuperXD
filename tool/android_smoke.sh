#!/usr/bin/env bash
# 安卓模拟器启动冒烟（手动入口；CI 跑不了，原因见 .github/workflows/ci.yml 的 android-build 上方）：模拟器要用真显卡（-gpu host），软件渲染下应用一出首帧模拟器就崩。
# 装开发包的调试包、冷启动、停 30 秒看进程还在不在、logcat 里有没有这个应用的 FATAL EXCEPTION；截图与 logcat 写进 build/android-smoke。
# 本机也能跑：模拟器开着、先 flutter build apk --debug --flavor production --target-platform android-x64，再 bash tool/android_smoke.sh。
set -euo pipefail

out=build/android-smoke
apk=build/app/outputs/flutter-apk/app-production-debug.apk
package=com.superxd.superxd
mkdir -p "$out"

adb wait-for-device
adb install -r "$apk"
adb logcat -c
adb shell am start -W -n "$package/.MainActivity" | tee "$out/start.txt"
sleep 30
adb exec-out screencap -p > "$out/launch.png"
adb logcat -d > "$out/logcat.txt"
# 先写进文件再找：管道里 grep -q 一找到就退出，前面的命令收到 SIGPIPE，pipefail 下会误判（iOS 冒烟遇到过）。
grep -A2 'FATAL EXCEPTION' "$out/logcat.txt" > "$out/fatal.txt" || true
if grep -q "Process: $package" "$out/fatal.txt"; then
  echo "::error::logcat 里有这个应用的 FATAL EXCEPTION，见产物 android-emulator-smoke"
  exit 1
fi
if ! adb shell pidof "$package" > "$out/pid.txt"; then
  echo "::error::启动 30 秒后应用进程不在了（闪退），截图与 logcat 见产物 android-emulator-smoke"
  exit 1
fi
echo "[AndroidSmoke] action=launch state=alive pid=$(tr -d '\r\n' < "$out/pid.txt")"
