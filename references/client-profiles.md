# Claude 客户端差异与专项排查

同一套网络配置，不同 Claude 客户端认的代理方式不同。先确认客户端类型，再套用对应路径。

## 浏览器（claude.ai 网页版）

**认什么**：Windows 系统代理（WinINET）或 TUN。

**专项检查**：

- DoH：设置里“使用安全 DNS”必须为灰色。
- IPv6：若 `browserleaks.com/ip` 显示公网 IPv6 直连绕过代理，在代理中开启 IPv6 接管或按需在活动网卡取消勾选 TCP/IPv6。
- 后台进程：`msedge.exe` / `chrome.exe` 常有十几个后台进程，改配置后必须全部结束（或使用任务管理器/`taskkill`）。
- 验证：`browserleaks.com/ip` 的公网 IP 应等于 L1 预期代理出口，且无意外的直连 IPv6。

**Claude 特有现象**：

- `claude.ai` 返回 `403` 且页面是 `Just a moment...` → Cloudflare 人机验证，不是网络不通；换浏览器/无痕窗口或稍后重试。
- 页面能打开但一直转圈、资源加载失败 → 查 `assets-proxy.anthropic.com` 是否可达。
- 登录后立刻被登出 → 先看出口 IP 是否频繁跳变，再看账号侧。

## Claude Code CLI

**认什么**：`HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY` 环境变量，或 TUN。

**专项检查**：

- 只开系统代理时，CLI 不会自动走代理。
- `NO_PROXY` 若包含目标域名，会绕过代理。
- `setx` 只影响新开的终端，旧终端要重开。
- 流式对话请求走 `api.anthropic.com`，而首次 `claude login` OAuth 授权还会唤醒浏览器访问 `claude.ai` / `console.anthropic.com`（或 `platform.claude.com`）并在本地回调端口完成登录——网页通不代表 CLI 通，API 通也不代表浏览器授权回调通。
- 验证：

```powershell
$env:HTTPS_PROXY="http://127.0.0.1:7890"
$env:HTTP_PROXY="http://127.0.0.1:7890"
curl.exe -s -m 10 https://ip.sb
curl.exe -s -o NUL -w "%{http_code}" -m 15 -X POST https://api.anthropic.com/v1/messages -H "content-type: application/json" -d "{}"
```

端口按实际混合端口填写。返回 `401/400` 说明网络已通，剩下是密钥或参数问题。

## Claude 桌面客户端

**认什么**：通常跟随系统代理或 TUN（Electron 类客户端）。

**专项检查**：

- 修改代理后必须完全退出（包括托盘图标），只关窗口不生效。
- 若客户端有内置网络/代理设置，确认没有被单独指到已失效的端口。
- 浏览器通、桌面端不通 → 桌面端进程未重启，或没有跟随系统代理。
- 客户端更新后可能重置网络设置，升级后重新核对一次。

## 通用程序

| 程序 | 认什么 | 备注 |
|---|---|---|
| Java 应用 | JVM 参数 `-Dhttps.proxyHost` / `-Dhttps.proxyPort` | 不读系统代理，也不读 `HTTPS_PROXY` |
| Node / npm | `HTTPS_PROXY` 或 npm 配置 | 部分工具忽略环境变量 |
| git | `git config --global http.proxy` | 与系统代理独立 |
| pip | `--proxy` 或环境变量 | 常被忽略 |
| Docker 容器 | 宿主机代理不会自动进入容器 | 需单独配置或使用 host 网络 |

**通用兜底**：开启 TUN 后，所有 TCP/UDP 流量在系统层被接管，不再依赖各程序是否认代理。代价是排障时更难区分“程序自己配置”和“TUN 接管”。

## 其他桌面 AI 客户端

同一套 L0–L4 方法同样适用；差异只在“它认哪种代理”。判断方法：

1. 进程名 → 判断程序类型（Electron / Go / Java / 原生）。
2. 关掉系统代理只留 TUN，看它是否恢复 → 说明它不认系统代理。
3. 只留系统代理、关 TUN，看它是否恢复 → 说明它跟随系统代理。
