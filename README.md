# 循环提醒

一个离线优先的循环任务倒计时工具。项目以 Web/PWA 为功能基准，并提供纯 SwiftUI 编写的 iOS App。

## 功能

- 创建、编辑、删除循环任务，循环时间支持天和小时
- 新建任务时可在高级设置中指定上次完成时间，从而校准首次到期时间
- 实时倒计时、到期高亮与当前周期进度
- iOS 支持为每个任务配置多条系统通知，可按到期、剩余百分比或剩余时间触发
- 短按一键“完成并重置”；长按可补记当前周期内的实际完成时间
- 记录每一次完成操作及当时的计划到期时间、循环间隔
- 统计：全局加权准时率、任务准时率、实际间隔中位数与实际／计划间隔比
- 统计宽限：全局默认 10%，任务可单独覆盖（含 0%），调整后重算全部历史
- JSON 备份导入和导出，Web 与 iOS 使用相同格式
- PWA 可离线使用并安装到主屏幕

> 统计从升级到 v2 后开始。旧任务的当前周期会保留，但不会把旧的 `lastCompletedAt` 伪造成历史完成记录。

## 统计口径

统计页使用全部历史，按当前生效的宽限配置重新计算。全局宽限在统计页设置，任务宽限在新增／编辑页设置；宽限仅影响统计，不改变计划到期时间或系统通知。

- 准时截止时间 = 该次计划到期时间 + 该次计划间隔 × 宽限百分比。恰好到达截止时间仍算准时，提前完成也算准时。
- 已完成周期按真实完成时间判定；当前未完成周期仅在超过宽限截止时间后纳入一次不准时，拖过多个间隔也只计一次。完成后以真实记录替代该周期，不重复计数。
- 单任务准时率 = 准时完成周期数 ÷（已完成周期数 + 当前超出宽限的未完成周期数）。无可评价周期时显示“—”。
- 全局加权准时率 = 准时完成周期的计划间隔之和 ÷ 全部纳入统计周期的计划间隔之和。历史周期使用记录当时的间隔，当前周期使用当前任务间隔。
- 实际间隔中位数只计算相邻真实完成记录的时间差，不使用创建时的周期起点或尚未完成周期；至少需要两条真实完成记录。
- 实际／计划间隔比先将每组实际间隔除以后一次完成记录中的计划间隔，再取中位数。100% 表示与计划一致；少量样本通过间隔样本数提示。
- 修改宽限立即重算历史，也可能使当前未完成周期退出统计分母；不改写原始完成记录。未来完成记录不参与当前统计。
- 删除任务会一起删除其历史并移出统计；导入备份会替换任务和全局宽限配置。

## 项目结构

| 平台 | 目录 | 技术 |
| --- | --- | --- |
| Web / PWA | `pwa/` | 原生 HTML/CSS/JS、Service Worker、IndexedDB |
| iOS | `ios/` | SwiftUI、Foundation、Xcode 工程，无第三方依赖 |

原 Expo / React Native 实现已经移除。

## Web 本地开发

需要 Node.js，无需安装 npm 依赖：

```bash
npm start
# http://localhost:8001
```

本地服务默认从 `8001` 端口启动。如果 `8001` 已被其他程序占用，会自动向上查找可用端口（最多 100 个端口），并在启动时打印实际地址；也可以用 `PORT` 环境变量指定固定端口（此时端口冲突会直接报错）。

运行数据迁移与统计测试：

```bash
npm test
```

PWA 由 GitHub Actions 部署到 GitHub Pages。推送 `main` 分支后会自动发布 `pwa/`。

## iOS 时间窗口统计

iOS 支持创建以来、近 7／30／90 天，默认近 30 天并记住选择。近 X 天为截至当前时刻的精确 24 × X 小时，前期为紧邻的等长窗口；窗口包含起点、不含终点。已完成周期按完成时间归属，当前逾期未完成仅按原规则加入本期，前期不重建历史未完成状态。

iOS 实际间隔改为算术平均数：先计算相邻真实完成记录的间隔，再按后一次完成时间归入窗口，对窗口内样本求平均，允许使用窗口之前的记录作为起点。计划比仍为每组实际／计划间隔比的中位数。PWA 暂时保留原有全历史和间隔中位数。

每个窗口内任务至少完成 3 次才展示指标并纳入总体准时率，否则显示样本不足；两期都达标才展示任务准时率百分点变化和平均间隔变化。总体纳入任务可能随窗口变化。创建以来只使用已保存的真实完成历史。

## iOS 开发

工程要求 iOS 16 或更高版本。使用 Xcode 打开：

```bash
open ios/CycleReminder.xcodeproj
```

当前这台 Mac 的 `xcode-select` 仍指向 Command Line Tools。命令行构建时可临时指定完整 Xcode：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild \
  -project ios/CycleReminder.xcodeproj \
  -scheme CycleReminder \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  test
```

也可以自行切换全局开发目录：

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
```

### 安装到自己的 iPhone

1. 用数据线或已配对的无线连接把 iPhone 接到 Mac，并在手机上信任这台电脑。
2. 在 Xcode 的 Settings → Accounts 中登录 Apple ID。
3. 打开 `CycleReminder` target 的 Signing & Capabilities，选择自己的 Team，并保持 Automatically manage signing 开启。
4. 如果 Bundle Identifier 与其他项目冲突，把 `com.wuth.cyclereminder` 改成自己唯一的标识。
5. 在 Xcode 顶部设备列表选择 iPhone，点击 Run。
6. 如果手机提示开发者模式，在“设置 → 隐私与安全性 → 开发者模式”中开启后重试。

### 一键续期

免费 Apple ID 的 Personal Team 描述文件从签发时起 7 天到期；重新构建或安装不会自动把旧描述文件的有效期重置为 7 天。首次按上面的步骤完成 Xcode 登录和签名设置后，以后可以：

1. 连接并解锁 iPhone。
2. 双击项目根目录的 **续期.command**。
3. 等待脚本申请描述文件、重新构建、验证有效期、覆盖安装并启动 App。
4. 查看脚本显示的实际到期时间（北京时间）；建议每隔 5～6 天续期，并以实际到期时间为准。

不要先从 iPhone 删除 App。脚本会使用原 Bundle Identifier 覆盖安装，以保留现有数据。

脚本会备份并移走 Mac 上与本 App 和开发者 Team 精确匹配的缓存描述文件，再执行 `clean build`，促使 Xcode 重新请求描述文件。备份保存在 `~/Library/Application Support/CycleReminder/Renewal/`，不包含手机任务数据。安装前会核对 Bundle Identifier、Team、目标设备和代码签名，并要求描述文件到期时间晚于本机找到的旧描述文件、剩余有效期至少 6 天。如果 Apple/Xcode 仍返回旧文件或校验失败，脚本会停止安装并明确报错；未完成安装时会恢复已移走的缓存文件，不覆盖 Xcode 新下载的同名文件。

该流程不卸载手机 App，也不修改任务数据存储逻辑。脚本固定校验当前应用标识 `com.wuth.cyclereminder` 和 Team `YBWKLTC4VN`；如果不符，应先检查原安装身份，不要为了消除错误随意更换这些值。需要额外的数据保障时，可在 App 内通过“备份 → 导出 JSON”保存任务和完成记录。

安装后如果手机提示「未受信任的开发者」：前往 设置 → 通用 → VPN与设备管理 → 开发者App，信任你的 Apple ID 后再打开。其他签名错误不能仅凭重新信任来判断已解决；自动启动失败时脚本会显示错误并提示手动检查。

续期流程离线回归测试（模拟 Xcode 和 iPhone，不触碰真实签名缓存或手机）：

```bash
python3 tests/renewal-script.test.py
```

如果脚本提示无法连接 Apple 开发者服务，请让 `developer.apple.com` 和 `idmsa.apple.com` 在 VPN/代理中直连，或在续期时临时关闭 VPN/代理。

## iOS WebDAV 同步

在任务页左上角菜单选择 **WebDAV 同步**。使用坚果云时：

1. 服务器地址填写 `https://dav.jianguoyun.com/dav/`。
2. 填写坚果云账号与“第三方应用管理”中生成的专用应用密码，点击“保存配置”。不使用主登录密码。
3. 点击“测试连接与读写”。App 会创建 `CycleReminder/` 目录，并创建、删除随机命名的临时测试文件，检查读写权限和条件写入；不修改现有任务文件。
4. 点击“立即同步”。共用文件为 `CycleReminder/sync-v1.json`，内容使用现有 v4 JSON 备份格式。同一账号、目录下的其他 iOS 设备配置相同地址后即可同步。

默认手动同步。开启自动同步后，App 回到前台或任务变更时会安排同步，变更会合并等待至少 5 秒，自动尝试约每分钟最多一次；不保证退出 App 后后台持续同步。离线修改保存在本机，联网后可立即同步或回到前台重试。同步后会重排本机系统通知。

- 首次同步合并不同 ID 的任务。相同 ID 内容不同或全局宽限不同，会提示冲突；不会按设备时间强行覆盖。
- 后续以本机上次成功同步的快照为基线，合并不同任务的修改及删除；同一任务两端同时修改（含完成记录、删除与编辑）会暂停并要求选择。选择“使用本机全部数据”或“使用云端全部数据”会**整体替换另一端**，需要二次确认；确认前若云端再次变化，须重新同步。也可以先导出 JSON，手动整理数据后重试。
- 应用远端变化或覆盖前，在本机保存两端恢复副本；设置页可导出副本，文件名的 `local` / `remote` 区分来源，再通过原有“导入 JSON”恢复。副本不自动清理。
- 每次需要上传时先用临时文件验证服务器遵守条件写入；首次创建使用 `If-None-Match: *`，覆盖使用强 ETag 与 `If-Match`。不支持此能力的 WebDAV 服务会报错并停止，避免静默覆盖。同步文件缺失但本机已有同步历史时，也会停止上传，需先恢复云端文件。
- 仅接受 HTTPS，拒绝自动重定向；密码保存在本机钥匙串，不进入备份、日志或仓库。更换设备需重新填写连接配置。断开保留两端任务及本机同步基线。
- 坚果云实际账号连接和读写仍需用户配置后验证。网页版当前仍使用 JSON 导入／导出，不会自动参与同步。

## Web 数据迁移到 iOS

iOS 已支持直接连接 WebDAV（见下方说明）；网页版暂未接入同步。网页中转可先按 [`webdav-probe/README.md`](webdav-probe/README.md) 部署独立的 Cloudflare Workers 只读连接测试。

浏览器的 IndexedDB 和 iOS App 沙箱互相隔离，不能自动读取。迁移方式：

1. 在 Web 的任务页选择“导出 JSON”，浏览器会直接下载带时间戳的 `.json` 文件。
2. 通过 AirDrop、iCloud Drive 或“文件”App 把下载的文件放到 iPhone。
3. 在 iOS App 任务页左上角“备份”菜单选择“导入 JSON”。
4. 确认任务数和完成记录数后替换本机数据。

v4 备份在顶层新增全局 `gracePercentage`，任务中的同名字段为可选覆盖值（缺省或 null 表示跟随全局）；旧备份导入时全局宽限默认为 10%。v3 的 `reminders` 字段继续保留：

```json
{
  "schemaVersion": 4,
  "gracePercentage": 10,
  "exportedAt": "2026-07-22T08:00:00.000Z",
  "tasks": [
    {
      "id": "task-id",
      "name": "换滤芯",
      "gracePercentage": null,
      "intervalHours": 48,
      "lastCompletedAt": "2026-07-22T08:00:00.000Z",
      "nextDueAt": "2026-07-24T08:00:00.000Z",
      "createdAt": "2026-07-20T08:00:00.000Z",
      "completions": [
        {
          "id": "completion-id",
          "completedAt": "2026-07-22T08:00:00.000Z",
          "scheduledDueAt": "2026-07-22T09:00:00.000Z",
          "intervalHours": 48
        }
      ],
      "reminders": [
        {
          "id": "due-reminder-id",
          "mode": "due",
          "amount": 0
        },
        {
          "id": "percentage-reminder-id",
          "mode": "remainingPercentage",
          "amount": 20
        },
        {
          "id": "time-reminder-id",
          "mode": "remainingTime",
          "amount": 24
        }
      ]
    }
  ]
}
```

Web 和 iOS 都能继续导入旧版的顶层任务数组备份。

## 当前提醒方式

iOS App 可在新增或编辑任务时添加多条系统提醒。首次保存带提醒的任务时，App 会请求通知权限；如果曾拒绝，可前往“设置 → 通知 → 循环提醒”重新开启。完成并重置任务后，提醒会按照新周期自动重排。

Web/PWA 仍只在页面内显示到期状态，不发送系统通知，但导入、编辑和导出时会保留 iOS 的提醒配置。
