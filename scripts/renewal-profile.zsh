# Shared by 续期.command and its offline regression tests.

renewal_decode_profile() {
    /usr/bin/security cms -D -i "$1" > "$2" 2>/dev/null
}

renewal_profile_matches() {
    local plist="$1" bundle="$2" team="$3" actual_team app_identifier
    actual_team="$(/usr/bin/plutil -extract TeamIdentifier.0 raw "$plist" 2>/dev/null)" || return 1
    app_identifier="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$plist" 2>/dev/null)" || return 1
    [[ "$actual_team" == "$team" && "$app_identifier" == "$team.$bundle" ]]
}

renewal_profile_has_device() {
    /usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' "$1" 2>/dev/null |
        /usr/bin/sed 's/^[[:space:]]*//;s/[[:space:]]*$//' |
        /usr/bin/grep -Fxq -- "$2"
}

renewal_profile_expiry() {
    local iso_date
    iso_date="$(/usr/bin/plutil -extract ExpirationDate raw "$1" 2>/dev/null)" || return 1
    /bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$iso_date" '+%s' 2>/dev/null
}

renewal_validate_profile() {
    local plist="$1" bundle="$2" team="$3" device="$4" previous_expiry="$5" now="$6"
    local expiry remaining
    if ! renewal_profile_matches "$plist" "$bundle" "$team"; then
        print -u2 '描述文件的 App 标识或开发者 Team 不符，已停止安装。'
        return 1
    fi
    if ! renewal_profile_has_device "$plist" "$device"; then
        print -u2 '描述文件不包含当前 iPhone，已停止安装。'
        return 1
    fi
    expiry="$(renewal_profile_expiry "$plist")" || {
        print -u2 '无法读取描述文件到期时间，已停止安装。'
        return 1
    }
    remaining=$(( expiry - now ))
    print "📅 描述文件到期：$(TZ=Asia/Shanghai /bin/date -r "$expiry" '+%Y-%m-%d %H:%M:%S Asia/Shanghai')"
    print "   剩余：$(( remaining / 86400 )) 天 $(( remaining % 86400 / 3600 )) 小时"
    if (( expiry <= previous_expiry )); then
        print -u2 '到期时间没有延长：Xcode 仍返回旧描述文件，本次未完成续期，已停止安装。'
        return 1
    fi
    # Allow issuance/build time while ensuring an early renewal buys a useful interval.
    if (( remaining < 6 * 86400 )); then
        print -u2 '描述文件剩余有效期不足 6 天，本次未完成续期，已停止安装。'
        return 1
    fi
}

renewal_restore_profiles() {
    local index
    for (( index = 1; index <= ${#renewal_originals}; index++ )); do
        # Never overwrite a profile Xcode has newly downloaded.
        if [[ ! -e "${renewal_originals[$index]}" ]]; then
            /bin/cp -p "${renewal_backups[$index]}" "${renewal_originals[$index]}" || return 1
        fi
    done
}
