# 循环提醒

一个离线优先的循环任务倒计时工具。记录需要定期完成的事项（如换滤芯、浇花、备份），自动计算剩余时间，到期醒目提醒。

## 功能

- 创建任务，设置循环间隔（小时）
- 实时倒计时，到期高亮显示
- 一键"完成并重置"，自动计算下次到期时间
- 导入/导出 JSON 备份
- PWA 离线可用，可安装到桌面

## 技术栈

| 平台 | 目录 | 技术 |
|------|------|------|
| iOS / Android | `App.tsx` | Expo SDK 54 + React Native |
| Web (PWA) | `pwa/` | 原生 HTML/CSS/JS，Service Worker + IndexedDB |

两套实现功能完全一致，共享相同的数据格式。

## 本地开发

```bash
# 安装依赖
npm install

# 启动 Expo 开发服务器
npm start
```

```bash
# 启动 PWA 本地服务器
node pwa-server.js
# 访问 http://localhost:4173
```

## 部署

PWA 通过 GitHub Actions 自动部署到 GitHub Pages。推送 `main` 分支即触发。

在线地址：`https://watice555.github.io/reminder/`
