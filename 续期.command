#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_PATH="$SCRIPT_DIR/ios/CycleReminder.xcodeproj"
SCHEME="CycleReminder"
XCODE_PATH="/Applications/Xcode.app"
DERIVED_DATA_PATH="/tmp/CycleReminderRenewal"
# Guard the identity of the existing installation. Do not change these to fix signing errors.
EXPECTED_BUNDLE_ID="com.wuth.cyclereminder"
EXPECTED_TEAM_ID="YBWKLTC4VN"
RENEWAL_ROOT="$HOME/Library/Application Support/CycleReminder/Renewal"
source "$SCRIPT_DIR/scripts/renewal-profile.zsh"
launch_failed=0
installed=0
lock_acquired=0
backup_dir=""
expiry_label=""
typeset -a renewal_originals=() renewal_backups=()

finish() {
    local exit_code=$?
    trap - EXIT

    if (( ! installed && ${#renewal_originals} )); then
        if ! renewal_restore_profiles; then
            print "⚠️ 恢复本地描述文件失败，备份仍保存在：$backup_dir"
            exit_code=1
        fi
    fi
    if (( lock_acquired )); then
        /bin/rmdir "$RENEWAL_ROOT/active.lock" 2>/dev/null || true
    fi

    if (( exit_code == 0 )); then
        if (( launch_failed )); then
            print ""
            print "✅ 描述文件有效期已验证并完成覆盖安装（自动启动未成功，请手动打开）。"
        else
            print ""
            print "✅ 续期完成，CycleReminder 已重新安装并启动。"
        fi
        print "📅 本次描述文件到期：$expiry_label"
    else
        print ""
        print "❌ 续期失败，请查看上方报错。"
    fi

    if [[ -t 0 ]]; then
        read -r "?按回车键关闭窗口…"
    fi

    exit "$exit_code"
}

trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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
if ! destinations="$("$DEVELOPER_DIR/usr/bin/xcodebuild" \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -showdestinations 2>&1)"; then
    print -r -- "$destinations"
    print "Xcode 查询设备失败，请先解决上方 Xcode 错误后重试。"
    exit 1
fi

# Xcode can exit successfully even when its device plug-in cannot load.
if [[ "$destinations" == *"DVTCoreDeviceCore"* &&
      "$destinations" == *"Symbol not found:"* ]]; then
    print -r -- "$destinations"
    print "Xcode 设备组件版本不匹配，无法查找 iPhone。"
    print "请打开 /Applications/Xcode.app，完成所需组件安装后重试。"
    exit 1
fi

device_id="$(print -r -- "$destinations" | \
    /usr/bin/sed -nE '/platform:iOS,/p' | \
    /usr/bin/sed -e '/Simulator/d' -e '/placeholder/d' | \
    /usr/bin/sed -nE 's/.*id:([^,} ]+).*/\1/p' | \
    /usr/bin/head -n 1)"

if [[ -z "$device_id" ]]; then
    print -r -- "$destinations"
    print "没有找到可用的 iPhone。"
    print "请连接并解锁 iPhone，在手机上信任这台 Mac，然后重试。"
    exit 1
fi

print "📱 已找到 iPhone：$device_id"
umask 077
/bin/mkdir -p "$RENEWAL_ROOT"
if ! /bin/mkdir "$RENEWAL_ROOT/active.lock" 2>/dev/null; then
    print "另一个续期进程可能正在运行，请等它结束后重试。"
    print "若上次被强制终止，请确认没有续期进程后移除：$RENEWAL_ROOT/active.lock"
    exit 1
fi
lock_acquired=1
backup_dir="$(/usr/bin/mktemp -d "$RENEWAL_ROOT/profiles.XXXXXX")"
print "📁 本次 Mac 签名缓存备份：$backup_dir"
print "   此备份仅包含签名描述文件，不是手机任务数据备份。"

previous_expiry=0
app_path="$DERIVED_DATA_PATH/Build/Products/Debug-iphoneos/CycleReminder.app"
old_profile="$app_path/embedded.mobileprovision"
if [[ -f "$old_profile" ]]; then
    if ! renewal_decode_profile "$old_profile" "$backup_dir/previous.plist" ||
        ! renewal_profile_matches "$backup_dir/previous.plist" "$EXPECTED_BUNDLE_ID" "$EXPECTED_TEAM_ID"; then
        print "旧构建的签名身份无法确认，已停止。请检查工程与旧构建，勿更改应用标识或卸载手机 App。"
        exit 1
    fi
    previous_expiry="$(renewal_profile_expiry "$backup_dir/previous.plist")"
fi

print "🔄 正在备份并移走本 App 的缓存描述文件…"
profile_index=0
for profile_dir in \
    "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" \
    "$HOME/Library/MobileDevice/Provisioning Profiles"; do
    for profile in "$profile_dir"/*.mobileprovision(N); do
        if ! renewal_decode_profile "$profile" "$backup_dir/candidate.plist"; then
            print "无法读取缓存描述文件：$profile；已停止，避免续用未检查的缓存。"
            exit 1
        fi
        # Leave other teams, apps and wildcard profiles untouched.
        if renewal_profile_matches "$backup_dir/candidate.plist" "$EXPECTED_BUNDLE_ID" "$EXPECTED_TEAM_ID"; then
            if renewal_profile_has_device "$backup_dir/candidate.plist" "$device_id"; then
                candidate_expiry="$(renewal_profile_expiry "$backup_dir/candidate.plist")"
                if (( candidate_expiry > previous_expiry )); then
                    previous_expiry=$candidate_expiry
                fi
            fi
            (( ++profile_index ))
            backup_path="$backup_dir/$profile_index.mobileprovision"
            /bin/cp -p "$profile" "$backup_path"
            renewal_originals+=("$profile")
            renewal_backups+=("$backup_path")
            printf '%s\t%s\n' "$profile" "$backup_path" >> "$backup_dir/manifest.tsv"
            /bin/rm "$profile"
        fi
    done
done
if (( previous_expiry > 0 )); then
    print "   原描述文件到期：$(TZ=Asia/Shanghai /bin/date -r "$previous_expiry" '+%Y-%m-%d %H:%M:%S Asia/Shanghai')"
fi
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
    clean build

if [[ ! -d "$app_path" ]]; then
    print "构建完成，但未找到 App：$app_path"
    exit 1
fi

bundle_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$app_path/Info.plist")"
if [[ "$bundle_id" != "$EXPECTED_BUNDLE_ID" ]]; then
    print "App 标识与原安装不一致，已停止安装。不要通过更改 Bundle Identifier 解决续期问题。"
    exit 1
fi
if ! renewal_decode_profile "$app_path/embedded.mobileprovision" "$backup_dir/built.plist"; then
    print "无法解析新构建的描述文件，已停止安装。"
    exit 1
fi
# Explicit exit keeps the top-level EXIT cleanup reliable with zsh's errexit in functions.
if ! renewal_validate_profile "$backup_dir/built.plist" "$EXPECTED_BUNDLE_ID" "$EXPECTED_TEAM_ID" \
    "$device_id" "$previous_expiry" "$(/bin/date '+%s')"; then
    exit 1
fi
/usr/bin/codesign --verify --deep --strict "$app_path"
new_expiry="$(renewal_profile_expiry "$backup_dir/built.plist")"
expiry_label="$(TZ=Asia/Shanghai /bin/date -r "$new_expiry" '+%Y-%m-%d %H:%M:%S Asia/Shanghai')"

print "📦 正在覆盖安装（不删除现有数据）…"
/usr/bin/xcrun devicectl device install app \
    --device "$device_id" \
    "$app_path"
installed=1

print "🚀 正在启动 CycleReminder…"
/bin/sleep 3

launch_app() {
    /usr/bin/xcrun devicectl device process launch \
        --device "$device_id" \
        "$bundle_id" 2>&1
}

launch_output=""
if ! launch_output="$(launch_app)"; then
    print "⏳ 自动启动未成功，5 秒后重试…"
    /bin/sleep 5
    if ! launch_output="$(launch_app)"; then
        launch_failed=1
        print ""
        if [[ "$launch_output" == *"not been explicitly trusted"* ]]; then
            print "ℹ️  描述文件有效期已验证且安装成功，手机提示开发者尚未受信任。"
            print "请在 iPhone 上操作一次："
            print "  1. 解锁 iPhone，点开「循环提醒」图标；"
            print "  2. 若提示「未受信任的开发者」，前往 设置 → 通用 → VPN与设备管理 →"
            print "     开发者App，点你的 Apple ID 并选择「信任」；"
            print "  3. 回到桌面重新点开 App；不需要卸载。"
        else
            print -r -- "$launch_output"
            print ""
            print "⚠️  续期和安装都已成功，只是自动启动失败。请解锁 iPhone 后手动点开「循环提醒」试试。"
        fi
    else
        print -r -- "$launch_output"
    fi
else
    print -r -- "$launch_output"
fi
