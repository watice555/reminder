# 坚果云连接测试（Cloudflare Workers）

这是独立的只读连接测试，不是完整同步功能。现有 iOS、PWA 任务及其存储不受影响。

浏览器打开 Worker 的测试页，提交中转密钥后，Worker 对固定的 `https://dav.jianguoyun.com/dav/` 发起 `PROPFIND Depth: 0`。只检查根目录元信息的响应状态，不列出目录内容，不返回坚果云响应正文，不创建、上传或删除文件。程序不记录账号、密码或请求正文。

## 1. 准备账号

- 注册或登录 [Cloudflare 控制台](https://dash.cloudflare.com/)。本阶段使用 Workers 免费方案即可，不需要购买服务器或域名。
- 在坚果云的“账户信息 → 安全选项 → 第三方应用管理”生成本应用专用的应用密码。使用坚果云账号和这个应用密码，不使用主登录密码。
- 用密码管理器生成一个至少 32 字符的随机密钥，作为 `PROBE_TOKEN`，单独保存。

账号、应用密码和密钥均不需要发到聊天中，也不要写进代码或 Git。

## 2. 部署测试程序（控制台方式）

1. 在 Cloudflare 的 Workers & Pages 中创建 Worker，选择 Hello World/代码编辑方式，名称可用 `cycle-reminder-webdav-probe`。
2. 打开代码编辑器，用本目录 `worker.mjs` 的全部内容替换示例代码，保存并部署。它是独立 ES Module，不依赖其他文件或 npm 包。
3. 在此 Worker 的设置中找到 Variables and Secrets，添加以下三个变量，类型全部选择 **Secret**，然后应用／部署配置：

| 名称 | 内容 |
| --- | --- |
| `NUTSTORE_USERNAME` | 坚果云登录账号，通常是邮箱 |
| `NUTSTORE_APP_PASSWORD` | 坚果云生成的专用应用密码 |
| `PROBE_TOKEN` | 前一步生成的随机密钥，至少 32 字符 |

4. 确认 `workers.dev` 访问地址已启用，复制控制台给出的 HTTPS 地址。

设置项名称可能随控制台更新变化；参考 [Workers 控制台入门](https://developers.cloudflare.com/workers/get-started/dashboard/) 和 [Secrets 配置](https://developers.cloudflare.com/workers/configuration/secrets/)。

### 可选：命令行部署

在本目录运行（需要 Node.js 和 Cloudflare 登录）：

```bash
npx wrangler@4 login
npx wrangler@4 deploy
npx wrangler@4 secret put NUTSTORE_USERNAME
npx wrangler@4 secret put NUTSTORE_APP_PASSWORD
npx wrangler@4 secret put PROBE_TOKEN
```

每次 `secret put` 在交互提示中输入值，不把值附在命令行。项目忽略 `.dev.vars`、`.dev.vars.*` 和 `.wrangler/`。

## 3. 实际连接测试

1. 用日常使用的浏览器打开 Worker 的完整 HTTPS 地址（不要使用控制台的嵌入预览）。
2. 在页面输入 `PROBE_TOKEN`，点击“测试连接”。页面会跳转显示 JSON 结果，密钥不会放到 URL 或浏览器本地存储中。
3. `ok: true` 且 `upstreamStatus: 207` 表示这一次“浏览器 → Worker → 坚果云”的网络和账号认证检查成功。
4. 分别用电脑常用网络和手机移动网络测试，核对实际可达性。不要连续频繁点击。

| 结果 | 处理 |
| --- | --- |
| 测试页打不开 | 排查当前网络到 Worker 地址的访问；尚未进入坚果云测试 |
| 中转访问密钥不正确 | 核对输入值与 `PROBE_TOKEN` |
| 请配置三个 Secrets | 检查变量名称、类型、部署状态及密钥长度 |
| `upstreamStatus: 401` | 检查坚果云账号及应用密码 |
| `upstreamStatus: 429` | 等待后再试，避免高频请求 |
| 连接失败或超时 | Worker 到坚果云请求失败，15 秒连接测试超时；稍后复测 |

本阶段测试页面与 Worker 同域，**未验证 GitHub Pages 跨域接入、文件读写权限、并发保护或自动同步**。成功后再实现只允许指定网页来源的同步接口、记录合并和删除同步；不要把这个测试接口直接当作生产同步接口。未使用的测试 Worker 可在 Cloudflare 中删除，并撤销对应坚果云应用密码。

## 本地验证

在项目根目录运行 `npm test`。模拟测试覆盖鉴权失败、来源限制、请求大小、固定只读请求、上游错误、重定向和超时；不访问真实坚果云账号，不能代替部署后实测。
