# 每层的失败分支与修复

## 跨平台命令对照

| 目的 | Windows | macOS / Linux |
|---|---|---|
| 默认路由 | `Get-NetRoute -DestinationPrefix 0.0.0.0/0` | `ip route get 1.1.1.1` / `netstat -rn` |
| 网卡列表 | `Get-NetAdapter` | `ip link` / `ifconfig` |
| DNS 解析 | `nslookup 域名` / `Resolve-DnsName` | `dig 域名` / `getent hosts 域名` |
| HTTP 状态 | `curl.exe -s -o NUL -w "%{http_code}"` | `curl -s -o /dev/null -w "%{http_code}"` |
| 端口连通 | `Test-NetConnection 主机 -Port 443` | `nc -vz 主机 443` |
| IPv6 地址 | `ipconfig` / `Get-NetIPAddress -AddressFamily IPv6` | `ifconfig` / `ip -6 addr` |
| 系统代理 | 设置 → 网络和 Internet → 代理 | `scutil --proxy` / `env | grep -i proxy` |
| 代理进程 | `Get-Process` | `ps aux | grep -Ei 'clash|sing-box|v2ray|xray'` |

## L0 基础连通失败

| 现象 | 原因 | 动作 |
|---|---|---|
| 没有默认路由 | 网卡禁用、没连 Wi-Fi、DHCP 失败 | 启用网卡；`ipconfig /renew`；重连 Wi-Fi |
| 解析失败 | DNS 服务器不可达、配置异常，或基线域名在当前网络不可用 | 用用户所在网络可访问的基线域名复核；需要对比 DNS 时先确认用户所在网络政策允许使用所选解析器 |
| 解析正常但 HTTPS 超时 | 网关/防火墙/公司网络拦截 | 换网络对比；检查防火墙与安全软件 |
| 只有部分应用不通 | 应用级代理或 hosts 被改 | 检查 hosts、应用代理设置 |

L0 未通过时**不要**开 TUN、改 DNS 覆写或换节点，否则会把基础故障和代理故障混在一起。

## L1 代理链路失败

### 先识别工具（不要假设是 Clash）

```powershell
Get-Process | Where-Object { $_.ProcessName -match 'clash|mihomo|sing-box|v2ray|xray|FlClash|shadowsocks|warp' }
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable
netsh winhttp show proxy
Get-NetAdapter | Where-Object { $_.InterfaceDescription -match 'Tunnel|WinTun|Mihomo|sing' }
```

| 工具 | 判断依据 | 接管方式 |
|---|---|---|
| Clash Verge | `verge-mihomo.exe` + `Mihomo` 网卡 | 系统代理或 TUN |
| FlClash | `FlClash` 进程 | 系统代理或 TUN |
| sing-box / v2rayN / xray | 同名进程 | 各自系统代理或 TUN |
| WARP | `warp-svc` | 独立虚拟网卡，常与 Clash 冲突 |
| Proxifier | `Proxifier` 进程 | 按进程规则，不依赖系统代理 |
| 公司 VPN | 厂商客户端 | 全局路由，可能与代理互斥 |

**同时运行两个接管型工具（如 WARP + Clash）会互相抢路由**，不同程序可能走不同出口。先只留一个。

### 出口仍为直连基线 IP（未走预期代理）

按概率排查：

1. **代理没开**：进程不存在 → 启动。
2. **只开了端口，没有接管目标程序**：系统代理关、TUN 关、程序又只认环境变量 → 打开系统代理或 TUN；注意 Windows 下 `curl.exe` 不读系统代理，仅开系统代理时需加 `-x` 测试。
3. **规则放行成 DIRECT**：规则模式下目标域名命中 DIRECT → 临时切全局验证；确认后修规则。
4. **程序不认系统代理**：Claude Code CLI / Node / Go / Rust / Java 等程序可能只认环境变量 → 设 `HTTPS_PROXY` 或开 TUN。
5. **代理端口本身不通**：绕过应用直接指定本地代理端口测试：

```powershell
curl.exe -x http://127.0.0.1:7890 -s -m 10 https://ip.sb
```

   - 这样能走出预期代理出口 IP、目标应用却不能 → 应用没走代理（回到 2/4）。
   - 这样也不通或仍是直连 IP → 代理端口未监听或节点本身有问题（检查代理端口设置并换节点）。

把端口换成实际混合端口（Clash 常见 7890/7897，以界面为准）。

### TUN 开了但没接管

- 确认内核已重载（开关后等几秒，或重启内核）。
- Windows 上 TUN 通常需要服务模式/管理员权限；查看 Verge 是否提示“服务未安装”。
- 检查是否出现 `Mihomo`/`Meta` 虚拟网卡且状态 Up。
- 旧连接不会自动迁移：完全结束目标程序再重启。

## L2 解析与泄漏失败

### DNS

- `nslookup 目标域名` 返回 `198.18.x.x`：fake-ip，正常。
- 返回真实 IP：
  - 开了 TUN 但 DNS 覆写没开 → 打开 DNS 覆写并重启内核。
  - 没开 TUN、只用系统代理 → **本地 DNS 解析是正常的**，因为浏览器把域名交给代理由远端解析；只有在你要求“解析也不暴露给本地运营商”时才需要 TUN + DoH。
- 返回 `127.0.0.1`：系统 DNS 指向本机但代理未监听 → 关闭 DNS 覆写或修复代理。

### 浏览器 DoH

| 浏览器 | 位置 | 通过标准 |
|---|---|---|
| Edge | 设置 → 隐私、搜索和服务 → 安全性 → 使用安全 DNS | 开关灰色 |
| Chrome | 设置 → 隐私和安全 → 安全 → 使用安全 DNS | 开关灰色 |
| Firefox | 设置 → 隐私与安全 → 启用基于 HTTPS 的 DNS | 关闭或“关闭保护” |

只换下拉框里的提供商、开关仍为绿色 = 仍然开启。

### IPv6 绕过

判断：

```powershell
curl.exe -6 -s -m 8 https://ip.sb
ipconfig | findstr /i "IPv6"
```

返回非链路本地公网 IPv6 只代表该命令能通过 IPv6 访问目标；需从目标客户端验证其 IPv6 出口是否绕过预期代理。不同地区的合法公网 IPv6 前缀不同，不要用固定前缀名单判定。

关闭（按影响从小到大）：

```powershell
# Windows：单网卡，可逆
ncpa.cpl   # 右键活动网卡 → 属性 → 取消勾选 Internet 协议版本 6
```

```bash
# macOS：网络 → 详情 → TCP/IP → 配置 IPv6 → 仅本地链路
# Linux：临时
sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1
```

全局禁用（注册表 / sysctl 持久化）副作用大，需管理员并重启，只有明确需要时才做，且先记录原值。

### WebRTC

- TUN 模式：UDP 也被接管，通常显示 `No Leak`。
- 仅系统代理：浏览器可能用 STUN 直接发 UDP，暴露真实地址。
- 处理：改用 TUN；或在浏览器策略里限制非代理 UDP（企业策略 `WebRtcIPHandling`）。
- 这是隐私问题，不影响“能不能打开网页”。

### 改完必须重启浏览器

`msedge.exe` / `chrome.exe` 会有十几个后台进程，只关窗口不清进程，旧 DNS 与连接仍在。重测用无痕窗口。

```powershell
taskkill /f /im msedge.exe
taskkill /f /im chrome.exe
ipconfig /flushdns
```

## L3 目标可达失败

| 现象 | 定位命令 | 含义 |
|---|---|---|
| 连接超时 | `Test-NetConnection claude.ai -Port 443` / `nc -vz` | DNS 或 TCP 不通，回 L1 |
| 域名解析失败 | `nslookup claude.ai` | DNS 问题，回 L2 |
| 证书错误 | `curl.exe -vI https://claude.ai` | 中间人/节点劫持，换节点 |
| 403 | 看响应体前 200 字 | 地区限制或风控，进 L4 |
| 401 / 400 | 忽略 | 网络已通，属于鉴权/参数 |
| 仅 IPv6 失败 | `curl.exe -6` vs `-4` | IPv6 路径坏，回 L2 |

`403` 时抓响应体：

```powershell
curl.exe -s -m 15 -X POST https://api.anthropic.com/v1/messages -H "content-type: application/json" -d "{}"
```

- 含 `authentication_error` → 401 类，网络正常。
- 含 `forbidden` / `Request not allowed` / `unsupported_country` → 地区或策略限制。
- 含 Cloudflare 验证页 → 风控/人机验证，不是网络不通。

## L4 使用条件失败

见 `references/claude-readiness.md`。核心原则：网络层全通过后仍 403/429/验证码，就不要再动网络配置。
