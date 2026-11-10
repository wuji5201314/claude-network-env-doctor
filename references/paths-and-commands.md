# 路径与命令速查（Windows 取证与常见代理工具）

本文件补充 `SKILL.md` 未展开的本地取证命令、常见代理工具配置路径与 Windows 平台高频易错点。

## 1. 代理接管状态全景取证（Windows）

Windows 下共有四套相互独立的代理机制，排障时需先确认哪一套处于激活状态：

```powershell
# 1) 代理相关进程（区分核心进程与辅助服务）
Get-Process | Where-Object { $_.ProcessName -match 'clash|mihomo|sing-box|v2ray|xray|FlClash|shadowsocks|warp|nekoray|hiddify|proxifier' } | Select-Object Id, ProcessName, Path

# 2) WinINET 系统代理（浏览器、Electron 桌面端使用）
Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -Name ProxyEnable, ProxyServer, AutoConfigURL -ErrorAction SilentlyContinue

# 3) WinHTTP 代理（部分系统服务使用，与 WinINET 独立）
netsh winhttp show proxy

# 4) TUN 虚拟网卡（系统级 L3 接管，所有进程通用）
Get-NetAdapter | Where-Object { $_.Name -match 'Mihomo|Meta|Clash|sing|TUN|WARP|utun' -or $_.InterfaceDescription -match 'Tunnel|WinTun|Mihomo|sing|WireGuard|TAP' } | Select-Object Name, InterfaceDescription, Status, ifIndex

# 5) 代理环境变量（CLI、curl.exe、Node/Python/Go 等使用）
Get-ChildItem Env: | Where-Object { $_.Name -match '^(HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY)$' }
reg query "HKCU\Environment" 2>$null | findstr /i "PROXY"
```

## 2. 本地代理端口监听验证

若开启了系统代理或配置了 `HTTPS_PROXY`，先确认本地代理端口确实在监听：

```powershell
# 查看常见代理端口（如 7890, 7897, 10808, 10809, 2080）是否被监听及对应 PID
Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
  Where-Object { $_.LocalPort -in @(7890, 7891, 7897, 1080, 10808, 10809, 2080) } |
  Select-Object LocalAddress, LocalPort, OwningProcess, @{N='Process';E={(Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName}}
```

## 3. 常见代理工具配置与日志路径（示例）

本 skill 不绑定特定工具；需核对规则、端口或内核报错时，可按实际安装工具查看对应目录（只读排查，勿随意覆写）：

| 工具 | 关键路径（Windows） | 说明 |
|---|---|---|
| **Clash Verge Rev** | `%APPDATA%\io.github.clash-verge-rev.clash-verge-rev\config.yaml` | 内核实际加载的运行时配置 |
| | `%APPDATA%\io.github.clash-verge-rev.clash-verge-rev\clash-verge.yaml` | 界面设置（混合端口、系统代理、TUN 开关） |
| | `%APPDATA%\io.github.clash-verge-rev.clash-verge-rev\dns_config.yaml` | DNS 覆写配置 |
| | `%APPDATA%\io.github.clash-verge-rev.clash-verge-rev\logs\service\` | 服务模式与内核日志 |
| **FlClash** | `%APPDATA%\com.follow.clash\` | 配置文件与运行日志 |
| **v2rayN** | `<v2rayN安装目录>\guiConfigs\guiNConfig.json` | 端口、路由与核心设置 |
| | `<v2rayN安装目录>\binConfigs\` | 实际生成的 Xray / sing-box 运行配置 |
| **Hiddify / NekoBox** | `%APPDATA%\Hiddify\` 或程序目录下 `config\` | sing-box 配置与日志 |

## 4. Windows 平台常见坑速查

- **PowerShell 的 `curl` 别名陷阱**：Windows PowerShell 5.1 中 `curl` 是 `Invoke-WebRequest` 的别名，参数语法完全不同，必须显式写 `curl.exe`。
- **`curl.exe` 不读 Windows 系统代理**：仅开启系统代理（未开 TUN、未设 `HTTPS_PROXY` 环境变量）时，直接跑 `curl.exe https://ip.sb` 会走直连；必须加 `-x http://127.0.0.1:<端口>` 才能测试系统代理端口。
- **`nslookup` 输出误读**：`nslookup` 第一段 `Address:` 是本地 DNS 服务器自身的地址（如 `192.168.1.1`），不是域名的解析结果；PowerShell 下推荐用 `Resolve-DnsName claude.ai` 获取结构化结果。
- **`setx` 不在当前终端生效**：`setx HTTPS_PROXY ...` 只写入注册表供新启动进程读取，当前已打开的终端窗口必须重开或用 `$env:HTTPS_PROXY="..."` 临时赋值。
- **浏览器与桌面端后台驻留**：关闭 Edge/Chrome 或 Claude 桌面端窗口后，后台进程（含系统托盘）仍保持旧连接与旧 DNS 缓存；修改代理、TUN 或 IPv6 后必须彻底结束进程再重测。
- **多代理工具抢路由**：同时运行两个接管型工具（例如 `verge-mihomo` 与 `warp-svc`），会导致不同客户端或不同连接命中不同虚拟网卡。
- **`ping` 不能代表 TCP/HTTPS 连通性**：代理（特别是 HTTP/SOCKS 系统代理）不转发 ICMP，且许多节点主动丢弃 ICMP；始终以 `curl.exe` 或 `Test-NetConnection -Port 443` 为准。
