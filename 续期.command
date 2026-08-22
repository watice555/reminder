#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_PATH="$SCRIPT_DIR/ios/CycleReminder.xcodeproj"
SCHEME="CycleReminder"
XCODE_PATH="/Applications/Xcode.app"
DERIVED_DATA_PATH="/tmp/CycleReminderRenewal"

finish() {
    local exit_code=$?
    trap - EXIT

    if (( exit_code == 0 )); then
        print ""
        print "✅ 续期完成，CycleReminder 已重新安装并启动。"
    else
        print ""
        print "❌ 续期失败，请根据上方报错检查网络、Xcode 账号和手机连接状态。"
    fi

    if [[ -t 0 ]]; then
        read -r "?按回车键关闭窗口…"
    fi

    exit "$exit_code"
}

trap finish EXIT

if [[ ! -x "$XCODE_PATH/Contents/Developer/usr/bin/xcodebuild" ]]; then
    print "未找到 $XCODE_PATH，请先安装 Xcode。"
    exit 1
fi

if [[ ! -d "$PROJECT_PATH" ]]; then
    print "未找到 Xcode 工程：$PROJECT_PATH"
    exit 1
fi

export DEVELOPER_DIR="$XCODE_PATH/Contents/Developer"

print "🌐 正在检查 Apple 开发者服务…"
for apple_service in "https://developer.apple.com/" "https://idmsa.apple.com/"; do
    if ! /usr/bin/curl -sS -o /dev/null \
        --connect-timeout 8 \
        --max-time 15 \
        "$apple_service"; then
        print "无法连接 $apple_service"
        if /usr/bin/pgrep -if "FlClash" >/dev/null; then
            print "检测到 FlClash 正在运行。请让 Apple 开发者域名直连，或在续期时临时关闭 FlClash。"
        else
            print "请检查网络、VPN 或代理设置后重试。"
        fi
        exit 1
    fi
done

print "🔎 正在查找已连接的 iPhone…"
destinations="$("$DEVELOPER_DIR/usr/bin/xcodebuild" \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -showdestinations 2>/dev/null)"

device_id="$(print -r -- "$destinations" | \
    /usr/bin/sed -nE '/platform:iOS,/p' | \
    /usr/bin/sed -e '/Simulator/d' -e '/placeholder/d' | \
    /usr/bin/sed -nE 's/.*id:([^,} ]+).*/\1/p' | \
    /usr/bin/head -n 1)"

if [[ -z "$device_id" ]]; then
    print "没有找到可用的 iPhone。"
    print "请连接并解锁 iPhone，在手机上信任这台 Mac，然后重试。"
    exit 1
fi

print "📱 已找到 iPhone：$device_id"
print "🔨 正在重新签名和构建…"

"$DEVELOPER_DIR/usr/bin/xcodebuild" \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination "platform=iOS,id=$device_id" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    -quiet \
    build

app_path="$DERIVED_DATA_PATH/Build/Products/Debug-iphoneos/CycleReminder.app"

if [[ ! -d "$app_path" ]]; then
    print "构建完成，但未找到 App：$app_path"
    exit 1
fi

bundle_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$app_path/Info.plist")"

print "📦 正在覆盖安装（不删除现有数据）…"
/usr/bin/xcrun devicectl device install app \
    --device "$device_id" \
    "$app_path"

print "🚀 正在启动 CycleReminder…"
/usr/bin/xcrun devicectl device process launch \
    --device "$device_id" \
    "$bundle_id"
