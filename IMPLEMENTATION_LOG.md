# 实施记录

## 续期设备识别错误诊断与真机恢复

- 阶段总结：确认本机 Xcode 27.0 的 DVTCoreDeviceCore 因系统 CoreDevice 缺少符号而加载失败，原脚本丢弃 stderr 后误报未连接 iPhone。运行 devicectl 时工具自动安装匹配组件，随后 Xcode 恢复识别真机。续期脚本保留设备查询诊断，区分查询失败、组件符号不匹配和无设备，避免错误归因。
- 已执行的验证：`zsh -n 续期.command`、`git diff --check` 通过；15 项离线流程测试通过，新增设备插件失败（退出码为零）、查询失败、无设备三种情况，确认不进入构建或安装且保留签名缓存。真实运行续期，签名、有效期校验、覆盖安装成功，新描述文件到期为 2026-09-28 23:57:37 Asia/Shanghai；自动启动重试后仍提示开发者未受信任，需要用户在手机上信任后打开。未卸载 App，未验证手机内任务数据，未运行无关业务测试。
- 时间戳：2026-09-21 23:58:36 Asia/Shanghai
- 写入者模型：GPT-6
- 设备：TianhaodeMacBook-Pro（macOS 27.0，arm64）

## 提前续期的描述文件刷新与有效期校验

- 阶段总结：修复续期脚本在 Xcode 复用旧描述文件时仍报告成功的问题。备份并移走仅与本 App 和 Team 精确匹配的 Mac 签名缓存，执行 clean build，并在覆盖安装前校验应用标识、Team、设备、代码签名、到期时间延长和至少 6 天剩余有效期；显示北京时间到期时间。添加并发锁、失败恢复与备份路径清单，不覆盖新下载的同名描述文件。保持原 Bundle Identifier 和 Team，不卸载手机 App，不修改任务数据存储逻辑；纠正将普通签名错误解释为未信任开发者的提示，并更新 README。
- 已执行的验证：`zsh -n 续期.command`、`zsh -n scripts/renewal-profile.zsh`、`git diff --check` 通过；`python3 tests/renewal-script.test.py` 通过 14 项离线流程回归测试，覆盖成功续期、旧到期时间不变、有效期过短、旧构建基准、过期恢复、身份及设备不符、缺失到期时间、构建/签名/安装失败、缓存恢复不覆盖新下载文件、启动失败提示。使用真实本地构建产物只读验证 security/plutil/date 解析，确认原描述文件于 2026-09-13 23:27:32 Asia/Shanghai 到期。未执行真机签发、安装和手机数据前后对比，本阶段以隔离模拟验证脚本，未操作真实签名缓存或 iPhone；Apple 是否签发新文件需下次真机运行确认。未运行 Web/iOS 业务测试，因为未改动业务代码。
- 时间戳：2026-09-14 03:46:50 Asia/Shanghai
- 写入者模型：GPT-6
- 设备：TianhaodeMacBook-Pro（macOS 26.6.2，arm64）

## 自定义完成时间与补记完成

- 阶段总结：Web/PWA 与 iOS 新建任务时均可在折叠的高级设置中指定上次完成时间，以校准首次到期且不计入完成统计；任务卡片保留短按一键完成，并通过长按提供带时间范围校验的补记完成，两个例外流程都会在写入前再次确认。补记继续保存原计划到期时间和周期快照、重排 iOS 系统提醒；JSON schema 保持 v3 兼容。
- 已执行的验证：`node --check pwa/app.js` 与 `node --check pwa/model.js` 通过；`npm test` 通过 12 项 Web 测试；`xcodebuild -quiet -project ios/CycleReminder.xcodeproj -scheme CycleReminder -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' test` 通过 13 项 iOS 测试和完整构建；`git diff --check` 通过。使用本地浏览器验证高级设置默认折叠、自定义创建及补记的二次确认取消不写入、右键进入补记不误触普通完成、短按仅完成一次且控制台无错误；使用 iPhone 17 Pro 模拟器验证完成按钮的补记辅助动作、补记日期范围页面和普通短按重置。
- 时间戳：2026-08-30 18:24:28 Asia/Shanghai
- 写入者模型：未知（运行环境未暴露）
- 设备：TianhaodeMacBook-Pro（macOS 26.6.2，arm64）

## 忽略本地 Agent 元数据

- 阶段总结：将项目根目录下的 `.zcode/` 加入 Git 忽略规则，避免本地 Agent 计划与元数据进入工作区状态或后续提交。
- 已执行的验证：`git check-ignore -v .zcode/plans/plan-sess_59e25407-fbc2-463e-b1b5-206e28ad1b02.md` 确认忽略规则生效；`git diff --check` 通过。未运行功能测试，因本阶段仅修改 Git 忽略配置和实施记录，不涉及应用代码。
- 时间戳：2026-08-30 18:11:27 Asia/Shanghai
- 写入者模型：未知（运行环境未暴露）
- 设备：TianhaodeMacBook-Pro（macOS 26.6.2，arm64）

## iOS 续期后启动容错

- 阶段总结：审查并确认续期脚本的启动容错改动；App 覆盖安装后会等待并重试自动启动，若因开发者未信任或其他原因无法启动，则明确提示手动处理且不再将已完成的续期和安装误报为失败；README 补充了描述文件过期后重新信任开发者的指引。
- 已执行的验证：`zsh -n 续期.command` 语法检查通过；`npm test` 通过 7 项 Web 测试；`git diff --check` 通过。未执行真机续期，因该操作需要已连接的 iPhone，并会实际触发签名、构建与覆盖安装。
- 时间戳：2026-08-30 17:44:10 Asia/Shanghai
- 写入者模型：未知（运行环境未暴露）
- 设备：TianhaodeMacBook-Pro（macOS 26.6.2，arm64）

## iOS 多规则系统提醒

- 阶段总结：为每个循环任务加入可持久化的多提醒配置，支持到期时、剩余百分比和剩余时间三种模式；接入 iOS 本地通知权限、调度、重排与清理逻辑，并在任务新增、编辑、完成重置、导入、删除及 App 回到前台时同步通知。编辑页支持动态添加和删除提醒、阈值校验，任务卡片显示提醒数量。备份格式升级为 v3，Web/PWA 会保留 iOS 提醒字段但不调度系统通知。
- 已执行的验证：`npm test` 通过 7 项 Web 数据兼容测试；`xcodebuild ... test CODE_SIGNING_ALLOWED=NO` 在 iPhone 17（iOS 26.5）模拟器通过 8 项 iOS 单元测试和完整构建；使用模拟器检查三种提醒的动态表单、默认值、任务卡片显示及首次保存时的系统通知权限弹窗，未在检查中选择通知权限。
- 时间戳：2026-08-30 17:35:38 Asia/Shanghai
- 写入者模型：未知（运行环境未暴露）
- 设备：TianhaodeMacBook-Pro（macOS 26.6.2，arm64）
