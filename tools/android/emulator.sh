#!/bin/sh
# Boots an Android emulator without a window, for `run-*` and checks that
# mustn't show anything on the screen: a throwaway virtual device (in a
# temporary folder, not your ~/.android) from the newest system image
# installed for this machine's processor, on the last port adb looks at
# (5584; others' emulators start at 5554).
#
#   sh tools/android/emulator.sh        # boots it; prints the line to export
#   sh tools/android/emulator.sh stop   # stops it and removes the device
#
# Then: export ANDROID_SERIAL=emulator-5584 (with other devices about),
# zig build run-gallery -Dtarget=aarch64-linux-android, and pictures of it
# with adb exec-out screencap -p > shot.png.
set -eu
sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [ -z "$sdk" ]; then
	case "$(uname -s)" in
	Darwin) sdk="$HOME/Library/Android/sdk" ;;
	*) sdk="$HOME/Android/Sdk" ;;
	esac
fi
adb="$sdk/platform-tools/adb"
dir="${TMPDIR:-/tmp}/nanoui-emulator"
port=5584
serial="emulator-$port"

if [ "${1:-}" = stop ]; then
	if [ -f "$dir/pid" ]; then kill "$(cat "$dir/pid")" 2>/dev/null || true; fi
	rm -rf "$dir"
	exit 0
fi

case "$(uname -m)" in
arm64 | aarch64) abi=arm64-v8a arch=arm64 ;;
*) abi=x86_64 arch=x86_64 ;;
esac
# system-images/android-36/google_apis/arm64-v8a: the newest API's.
image="$(ls -d "$sdk"/system-images/*/*/"$abi" 2>/dev/null | sort -V | tail -n 1)"
if [ -z "$image" ]; then
	echo "nanoui: no $abi system image in $sdk: install one (Android Studio's SDK Manager)" >&2
	exit 1
fi
tag="$(basename "$(dirname "$image")")"
api="$(basename "$(dirname "$(dirname "$image")")")"

if "$adb" -s "$serial" get-state >/dev/null 2>&1; then
	echo "export ANDROID_SERIAL=$serial"
	exit 0
fi
mkdir -p "$dir/nanoui.avd"
cat >"$dir/nanoui.ini" <<EOF
avd.ini.encoding=UTF-8
path=$dir/nanoui.avd
target=$api
EOF
cat >"$dir/nanoui.avd/config.ini" <<EOF
avd.ini.encoding=UTF-8
AvdId=nanoui
abi.type=$abi
hw.cpu.arch=$arch
image.sysdir.1=system-images/$api/$tag/$abi/
tag.id=$tag
hw.cpu.ncore=4
hw.ramSize=3072
disk.dataPartition.size=6G
hw.lcd.density=420
hw.lcd.width=1080
hw.lcd.height=2400
hw.keyboard=yes
hw.gpu.enabled=yes
hw.gpu.mode=swiftshader_indirect
EOF
ANDROID_AVD_HOME="$dir" ANDROID_EMULATOR_HOME="$dir" ANDROID_SDK_ROOT="$sdk" nohup "$sdk/emulator/emulator" \
	-avd nanoui -port "$port" -no-window -no-audio -no-boot-anim -no-snapshot -no-metrics \
	-gpu swiftshader_indirect >"$dir/emulator.log" 2>&1 &
pid=$!
echo "$pid" >"$dir/pid"
# Booted once Android says so: a minute or two the first time, five at most.
waited=0
until [ "$("$adb" -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do
	if ! kill -0 "$pid" 2>/dev/null; then
		echo "nanoui: the emulator stopped:" >&2
		tail -n 5 "$dir/emulator.log" >&2
		exit 1
	fi
	if [ "$waited" -ge 300 ]; then
		echo "nanoui: the emulator didn't boot in five minutes (its log: $dir/emulator.log)" >&2
		exit 1
	fi
	sleep 2
	waited=$((waited + 2))
done
echo "export ANDROID_SERIAL=$serial"
