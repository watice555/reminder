# 循环提醒

一个离线优先的循环任务倒计时工具。项目以 Web/PWA 为功能基准，并提供纯 SwiftUI 编写的 iOS App。

## 功能

- 创建、编辑、删除循环任务，循环时间支持天和小时
- 实时倒计时、到期高亮与当前周期进度
- 一键“完成并重置”，从实际完成时刻计算下次到期时间
- 记录每一次完成操作及当时的计划到期时间、循环间隔
- 完成统计：今天、近 7 天、累计完成、准时率、7 日趋势与任务排行
- JSON 备份导入和导出，Web 与 iOS 使用相同格式
- PWA 可离线使用并安装到主屏幕

> 统计从升级到 v2 后开始。旧任务的当前周期会保留，但不会把旧的 `lastCompletedAt` 伪造成历史完成记录。

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

免费 Apple ID 的 Personal Team 签名每 7 天到期。首次按上面的步骤完成 Xcode 登录和签名设置后，以后可以：

1. 连接并解锁 iPhone。
2. 双击项目根目录的 **续期.command**。
3. 等待脚本自动重新签名、覆盖安装并启动 App。

不要先从 iPhone 删除 App。脚本会使用原 Bundle Identifier 覆盖安装，以保留现有数据。

如果脚本提示无法连接 Apple 开发者服务，请让 `developer.apple.com` 和 `idmsa.apple.com` 在 VPN/代理中直连，或在续期时临时关闭 VPN/代理。

## Web 数据迁移到 iOS

浏览器的 IndexedDB 和 iOS App 沙箱互相隔离，不能自动读取。迁移方式：

1. 在 Web 的任务页选择“导出 JSON”，浏览器会直接下载带时间戳的 `.json` 文件。
2. 通过 AirDrop、iCloud Drive 或“文件”App 把下载的文件放到 iPhone。
3. 在 iOS App 任务页左上角“备份”菜单选择“导入 JSON”。
4. 确认任务数和完成记录数后替换本机数据。

v2 备份格式为：

```json
{
  "schemaVersion": 2,
  "exportedAt": "2026-07-22T08:00:00.000Z",
  "tasks": [
    {
      "id": "task-id",
      "name": "换滤芯",
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
      ]
    }
  ]
}
```

Web 和 iOS 都能继续导入旧版的顶层任务数组备份。

## 当前提醒方式

到期状态会在打开 Web 或 iOS App 时醒目显示。当前版本尚未加入系统本地通知或后台推送。
