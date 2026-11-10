---
name: claude-network-env-doctor
description: 面向不同国家和网络环境的 Claude 连接诊断指南，按症状定位基础连通、代理路径、DNS/IPv6/WebRTC、Claude 端点和账号/地区可用性。指导 Windows、macOS、Linux 用户，代理工具无关；附带的一键脚本仅支持 Windows。用于 Claude 网页、CLI 或桌面客户端连接故障及明确的隐私泄漏告警。
---

# Claude 网络环境分层体检（L0 → L4）

## 这个 skill 解决什么

把“Claude 用不了”拆成五个可以单独回答的问题。**每层只回答一个**，通过才进入下一层，不通过就停在这一层给唯一修复路径。避免一上来就调代理、改 DNS、关 IPv6，最后不知道哪一步起了作用。

| 层 | 要回答的问题 | 失败典型表现 |
|---|---|---|
| L0 基础连通 | 这台机器能访问用户所在网络环境中的基线网站吗 | 多个普通网站均打不开 |
| L1 代理链路 | 目标客户端流量真的走预期代理了吗 | 出口仍为直连基线 IP，或代理端口未接管目标程序 |
| L2 解析与泄漏 | 浏览器有没有绕开代理 | DNS 泄漏、IPv6/WebRTC 暴露 |
| L3 目标可达 | Claude 的端点能不能到 | TLS 失败、超时、403 |
| L4 Claude 可用性 | 环境是否满足使用条件 | 地区不支持、账号风控 |

## 诊断流程（先缩小范围，再按需深入）

这是供不同地区、操作系统、网络和代理工具的用户复用的流程。先了解**操作系统、目标客户端、具体症状、影响范围、最近改动**中与当前判断有关的信息；用户未提及时不要假定地点、运营商、代理软件、权限或网络限制。不要为收集背景一次问完所有问题，先做不依赖缺失信息的诊断。

```text
选定客户端与症状
  ├─ 所有网站都打不开 → L0
  ├─ 只有 Claude/某客户端打不开 → L1（该客户端的代理路径）
  └─ 明确是隐私泄漏告警 → 只查 L2 对应项

L0 通过或不相关 → L1 代理是否接管目标客户端
L1 通过 → L3 对应 Claude 端点
L3 有 HTTP 响应 → 按状态码判断；仅在需要时查 L2 或 L4
```

L2 是按症状触发的**隐私与浏览器路径检查**，不是每次打开 Claude 的硬性前置条件：仅系统代理时，系统 DNS 返回真实 IP、存在本地 IPv6 或 WebRTC 候选，并不能单独证明 Claude 请求绕过代理。L4 只在服务端拒绝、限流、验证码或登录异常时进入。

## 怎么用（三种入口，选一个）

**A. 能跑命令（推荐）**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill-dir>\scripts\doctor.ps1"
```

执行只读快照，帮助识别本机代理状态及端点响应。它是**线索收集器，不是自动定责器**：进程、系统代理、出口 IP 都不能证明特定客户端实际走了同一条链路；请结合症状和目标客户端复核。默认会测 Claude 端点，加 `-NoClaude` 跳过 Claude 端点。

**B. 不能跑命令 / 远程指导别人**

先问客户端和症状，再只跑对应分支。每轮先问/测一项，避免一次抛五个问题。

**C. 已知某个 Claude 客户端有问题**

先跑 A 定位到具体层，再查 `references/client-profiles.md`（浏览器 / Claude Code CLI / Claude 桌面客户端）。

## 判定原则

1. **先按影响范围分流**：全网故障查 L0；单客户端故障先查该客户端代理路径；隐私告警只查相关泄漏项。
2. **逐步升级**：L0 未通过先修基础网络；L1 未证实目标客户端走代理时，不把 Claude 端点状态归因于 L3/L4。
3. **HTTP 响应意味着已到 HTTP 层**：401/400/403/429/5xx 不是 TCP 失败。按响应体和状态码分流，不把所有 403 都叫地区封锁。
4. **PASS 也记录**：只报告实际验证过的项目，未测项目标为未检查，不推断通过。
5. **不绑定工具**：Clash / FlClash / sing-box / v2rayN / WARP / 公司 VPN 都可能；先识别再用对应术语。
6. **区分网络、客户端、服务端问题**：出口 IP、ASN、地区和风控结果由节点或服务端共同决定，本机改 DNS 通常不能改变这些属性。

## L0：基础连通

**判据**：有默认路由 + 一个在用户所在网络可访问的基线域名能解析并建立 HTTPS。选择用户已知可访问的网站；以下用 `example.com` 举例，若被所在网络屏蔽，应换成当地可访问的基线站点。不要将某个国家或地区的门户网站设为全球默认探测目标。

```powershell
# Windows
Get-NetRoute -DestinationPrefix 0.0.0.0/0 | Select-Object -First 1
nslookup example.com
curl.exe -s -o NUL -w "%{http_code}" -m 8 https://example.com
```

```bash
# macOS / Linux
ip route get 1.1.1.1
getent hosts example.com
curl -s -o /dev/null -w "%{http_code}" -m 8 https://example.com
```

- PASS：路由存在、解析出 IP、返回 `200/301/302`。
- FAIL：先修网卡/DHCP/DNS/路由器，**不要动代理配置**。细节见 `references/ladder-details.md`。

## L1：代理链路

**判据**：目标客户端的请求确实经由预期代理出口。单次 `curl` 出口只代表当前 `curl` 的路径；它不能证明浏览器、CLI 或桌面客户端走了相同路径。不要用 IP 地址段猜测“本地运营商”，应与代理关闭时的基线出口或代理工具连接记录对照。

先识别当前用的是什么代理（进程 + 系统代理 + TUN 虚拟网卡），再测出口：

```powershell
# PowerShell 默认连（仅在开启 TUN 或设置了 HTTPS_PROXY/ALL_PROXY 时经由代理）
curl.exe -s -m 10 https://ip.sb
curl.exe -4 -s -m 10 https://ip.sb
curl.exe -6 -s -m 10 https://ip.sb

# 若仅开启 Windows 系统代理（未开 TUN、未设环境变量），curl.exe 不会自动读取系统代理，需显式指定端口测试代理本身：
curl.exe -x http://127.0.0.1:7890 -s -m 10 https://ip.sb
```

备用出口查询：`https://api.ipify.org`、`https://ipinfo.io/json`（端口 `7890` 替换为实际混合端口）。

- PASS：目标客户端的出口与代理关闭时的直连基线不同，且符合预期；需用该客户端对应的代理路径验证。
- WARN：出口是机房/托管 IP（`org` 含 hosting/cloud/vps/datacenter），能用但风控更敏感。
- FAIL：出口仍等于直连基线 IP → 目标流量没走代理。三种原因：没开代理、规则把这批流量放行成 DIRECT、代理没接管该程序（例如只开了系统代理但用 CLI 直连）。

工具无关的排查顺序与各工具对应操作见 `references/ladder-details.md`。

## L2：解析与泄漏

**触发条件**：用户遇到浏览器出口不一致，或明确报告 DNS/IPv6/WebRTC 泄漏。若问题只是客户端无法连接，先走 L1/L3。所谓“泄漏”须针对具体客户端请求验证；本机启用 IPv6 或 `nslookup` 返回真实 IP 本身不等于 Claude 流量绕过代理。

```powershell
nslookup claude.ai
ipconfig | findstr /i "IPv6"
Get-NetAdapterBinding -ComponentID ms_tcpip6 | Where-Object Enabled -eq $true
```

```bash
ifconfig | grep inet6          # macOS/Linux
```

- **fake-ip 不是问题**：`198.18.x.x` 说明代理接管了 DNS，是正常现象。
- **DNS 泄漏测试显示不同网络/地区的解析器可能是分流结果**，不能仅凭解析器地理位置判泄漏。详见 `references/false-positives.md`。
- **DoH 必须真关**：浏览器“使用安全 DNS”开关要变灰，只换提供商不算关。
- **IPv6 可能绕过代理**：公网 IPv6 只是风险信号；用浏览器实际出口或 `curl -6` 对照目标路径确认，不能仅凭网卡启用状态定为故障。

浏览器侧人工确认（无法可靠自动检测）：

| 检查 | 位置 | 通过标准 |
|---|---|---|
| DoH | 设置 → 隐私 → 使用安全 DNS | 开关灰色 |
| IPv6 | `browserleaks.com/ip` 或针对客户端的 IPv6 请求 | 无意外的直连公网 IPv6；是否关闭网卡 IPv6 按证据和需要决定 |
| 实际出口 | `browserleaks.com/ip` | 公网 IP = L1 出口，IPv6 为 `n/a` |
| WebRTC | `browserleaks.com/webrtc` | `No Leak`，本地 IP 隐藏 |

## L3：Claude 端点可达

**判据**：Claude 的三个入口在 TCP + TLS + HTTP 层能给出响应，并能区分是哪一层失败。

```powershell
curl.exe -s -o NUL -w "%{http_code}" -m 12 https://www.google.com/generate_204
curl.exe -s -o NUL -w "%{http_code}" -m 15 https://claude.ai
curl.exe -s -m 15 -X POST https://api.anthropic.com/v1/messages -H "content-type: application/json" -d "{}"
curl.exe -s -o NUL -w "%{http_code}" -m 15 https://assets-proxy.anthropic.com
```

三个入口对应三种用法：

| 端点 | 对应客户端 | 说明 |
|---|---|---|
| `claude.ai` | 浏览器 / 桌面客户端 | Web 与客户端主入口 |
| `api.anthropic.com` | Claude Code CLI / API | 流式请求走这里 |
| `assets-proxy.anthropic.com` | Web 前端资源 | 页面能开但加载失败时查它 |

判读（详细语义见 `references/claude-readiness.md`）：

| 结果 | 含义 | 下一步 |
|---|---|---|
| `204`（google） | 代理链路通 | 进入 L4 |
| 连接超时 / `000` | TCP 没通：节点或 DNS | 回 L1，换节点 |
| 证书错误 | TLS 被破坏或节点投毒 | 换节点，不要继续登录 |
| `401` / `400`（api） | 网络已通，只差鉴权 | 网络侧 PASS |
| `403` | 地区限制或风控 | 进入 L4 判断，不要继续调网络 |
| `5xx` | 服务端问题 | 等待或换时段 |

## L4：Claude 可用性

依次核对五项，前一项不通过就不要看后一项：

1. **地区**：API 返回 `403` 且提示地区不支持 → 该地区不在服务范围。本 skill 只做网络诊断，**不提供伪装地区、规避风控或绕过服务条款的方法**；应使用官方支持地区的合规访问方式。
2. **出口稳定**：连续两次 `curl https://ip.sb` 结果一致；出口频繁跳变会导致登录态反复失效。
3. **浏览器卫生**：DoH 已关、无公网 IPv6 绕过、WebRTC 无泄漏（L2 已确认）。这些是隐私要求，不是绕过手段。
4. **客户端路径正确**：
   - 浏览器 → 系统代理或 TUN；
   - Claude Code CLI → `HTTPS_PROXY` / `HTTP_PROXY` 环境变量，或 TUN；
   - Claude 桌面客户端 → 系统代理或 TUN，改完必须完全退出重启。
5. **账号信号**：`403` / `429` / 验证码 / 登录循环 → 账号或风控问题，**停止调网络**，改用账号侧处理。

通过标准：L0–L3 全 PASS，且 L4 五项无阻断。

## 报告模板

逐层汇报，先给结论再给动作：

```text
L0 基础连通   PASS   默认路由存在，基线站点 example.com 返回 200
L1 代理出口   PASS   154.x.x.x（US），节点稳定
L2 解析泄漏   WARN   目标客户端的 IPv6 出口与预期不一致
L3 端点可达   PASS   google 204 / claude.ai 302 / api 401
L4 Claude     WARN   IPv6 绕过未处理，其余无阻断

结论：网络与代理链路正常，问题收敛到浏览器 IPv6 绕过代理。
下一步：只做一件事——在代理配置中禁用/接管 IPv6 或按需在活动网卡关闭 TCP/IPv6，结束全部浏览器后台进程后复测。
```

## 边界

- 只做连通性、解析、泄漏与可达性诊断。
- 不提供伪造地区、指纹伪装、绕过风控或服务条款的方案。
- 不替用户执行破坏性网络改动（全局禁用 IPv6、改注册表、重装代理）而不说明影响。
- 涉及封号风险时，只陈述事实与官方政策，不承诺“这样就不会被封”。

## Resources

- `scripts/doctor.ps1`：Windows 专用 L0–L4 一键只读快照；macOS/Linux 按对应命令手动检查。脚本结果不能代表其他平台或目标客户端路径。
- `references/ladder-details.md`：每一层的失败分支、跨平台命令与修复操作。
- `references/claude-readiness.md`：Claude 端点语义、403/401 区分、三种客户端路径。
- `references/false-positives.md`：误报清单与概念纠错，避免过度配置。
- `references/client-profiles.md`：浏览器 / Claude Code CLI / Claude 桌面客户端差异。
- `references/paths-and-commands.md`：以 Clash Verge 为例的路径与 Windows 取证命令。
