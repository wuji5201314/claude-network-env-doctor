# Claude Network Environment Doctor (Claude 网络环境分层体检)

面向不同操作系统与代理工具的 Claude 连接诊断指南与只读体检脚本。

将常见的“Claude 用不了 / 转圈 / 403 / 登录循环”拆解为 5 个独立验证层（L0 → L4），**每层只聚焦一个根本问题**，通过才进入下一层，定位到哪一层就停在哪一层给出唯一修复路径，彻底避免盲目修改系统代理、关 IPv6、覆写 DNS 导致越调越乱。

---

## 诊断分层模型 (L0 → L4)

| 层级 | 检查核心 | 关注指标 / 判据 | 典型失败表现 |
|---|---|---|---|
| **L0 基础连通** | 本机物理网络是否正常 | 默认物理路由、当地可访问基线域名解析与 HTTPS | 多个普通网站均打不开、网卡未获取 IP |
| **L1 代理链路** | 流量是否确实经由代理出口 | 代理核心运行、系统代理/TUN/环境变量、实际出口 IP 与 ASN | 出口仍等于直连基线 IP、代理核心未启动 |
| **L2 解析与泄漏** | 解析与流量是否意外绕开代理 | fake-ip 接管、活动网卡 IPv6、浏览器安全 DNS (DoH)、WebRTC | 浏览器直连公网 IPv6 泄漏、DoH 绕过代理 |
| **L3 端点可达** | Claude 目标服务连通性 | TCP 握手、TLS 证书、HTTP 状态码（204/200/401/403/5xx） | 连接超时 (000)、TLS 握手失败、403 阻断 |
| **L4 可用性判定** | 服务可用条件与账号信号 | 地区限制提示、出口 IP 跳变、Cloudflare 人机验证、429 限流 | 明确提示地区不支持、频繁掉登录态、验证码死循环 |

---

## 快速上手

### 方式 A：Windows 一键只读快照（推荐）

项目内置了 Windows 专用的只读快照诊断脚本 [`scripts/doctor.ps1`](scripts/doctor.ps1)。该脚本不修改任何系统网络设置、不触碰敏感注册表键值，仅读取当前网络快照并输出结构化层级报告：

```powershell
# 完整体检（含 Claude 端点探测）
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\doctor.ps1"

# 仅检查网络基础与代理（跳过 Claude 端点探测）
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\doctor.ps1" -NoClaude

# 指定本地可访问的基线探测地址（默认 https://example.com/）
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\doctor.ps1" -BaselineUrl "https://example.com/"
```

#### 典型输出示例
```text
=== Claude Network Environment Doctor ===
time=2026-11-10 18:37:22

=== L0 basic connectivity ===
L0  default route                  PASS   count=2 physical_next_hop=192.168.0.1 primary_route=198.18.0.2
L0  dns resolve (baseline)         PASS   example.com -> 198.18.2.4
L0  baseline https                 PASS   example.com=200

=== L1 proxy path ===
L1  proxy tool                     PASS   clash-verge, verge-mihomo (services: clash-verge-service)
L1  capture mode                   PASS   TUN=Mihomo
L1  curl egress ipv4               INFO   154.29.145.163 (ambient curl path; verify target client uses same route)
L1  egress geo                     INFO   US / AS979 NetLab Global

=== L2 dns and leaks ===
L2  dns for claude.ai              PASS   198.18.0.47 (fake-ip, hijacked by TUN/DNS)
L2  ipv6 egress                    PASS   none
L2  ipv6 on active NIC             PASS   TCP/IPv6 disabled on active physical adapter
L2  browser processes              INFO   msedge=15 (kill all background processes after proxy/IPv6 changes)
L2  browser DoH                    MANUAL must be OFF (toggle grey), not just another provider
L2  WebRTC leak                    MANUAL browserleaks.com/webrtc should show No Leak

=== L3 reachability ===
L3  google 204                     PASS   204 (ambient curl path)
L3  claude.ai                      PASS   200
L3  api.anthropic.com              PASS   401 (network OK, auth/params missing)
L3  assets-proxy                   PASS   http 200

=== L4 Claude readiness ===
L4  region / policy                PASS   no region block observed on API endpoint
L4  egress stability               PASS   consistent (154.29.145.163)
L4  exit quality                   PASS   non-hosting range

=== verdict ===
fail=0 warn=0
No FAIL signal in this snapshot; this does not prove every layer or client path is healthy.
```

---

### 方式 B：跨平台（macOS / Linux）与无脚本排查

无法运行 PowerShell 脚本或在 macOS/Linux 环境下时，可直接参考主指南 [`SKILL.md`](SKILL.md) 与对照表：
- **L0 基础网络**：检查默认路由 (`ip route`) 与基础站点解析；
- **L1 代理链路**：确认代理核心进程存活，使用 `curl -s https://ip.sb` 核验出口 IP；
- **L2 泄漏排查**：核对网卡 IPv6 状态与浏览器安全 DNS (DoH)；
- **L3 端点验证**：使用 `curl` 针对目标接口发送轻量探测（状态码返回 `401`/`400` 即代表网络层已全通）。

---

## 客户端差异排查速查

不同客户端对代理的识别机制存在显著差异：

| 客户端类型 | 依赖的代理接管机制 | 常见陷阱与注意事项 |
|---|---|---|
| **浏览器 (Web)** | 系统代理 (WinINET / 系统设置) 或 TUN | 浏览器 DoH 开关未彻底关闭；公网 IPv6 绕过代理直连；修改代理后后台进程未退出。 |
| **Claude Code CLI** | 环境变量 (`HTTPS_PROXY` / `HTTP_PROXY`) 或 TUN | 默认不读 Windows 系统代理；`setx` 对当前已打开终端无效；OAuth 授权需经浏览器完成。 |
| **桌面客户端 (Desktop)** | 系统代理或 TUN | 关闭窗口后托盘后台进程依然驻留；网络配置更新后需彻底结束进程重启。 |

详细客户端配置细节见 [`references/client-profiles.md`](references/client-profiles.md)。

---

## 仓库结构与参考资料

```text
.
├── SKILL.md                         # 核心指南：L0-L4 诊断主流程、判定准则与报告模板
├── README.md                        # 项目说明文档
├── scripts/
│   └── doctor.ps1                   # Windows 自动化只读快照体检脚本 (L0-L4)
└── references/
    ├── claude-readiness.md          # Claude 各端点语义、403/401 细分与可用性检查清单
    ├── client-profiles.md           # 浏览器 / Claude Code CLI / 桌面端差异排查要点
    ├── false-positives.md           # 常见测试误报清单与网络概念纠错
    ├── ladder-details.md            # 每层故障分支详解与跨平台命令对照表
    └── paths-and-commands.md        # Windows 四套代理机制全景取证与工具配置路径
```

---

## 核心原则与合规边界

1. **只读诊断与非对抗性**：本项目仅专注于网络连通性、代理接管确认与隐私防漏诊断。
2. **不提供规避与伪装手段**：不提供任何形式的伪造地区、指纹欺骗、自动化绕过服务条款或对抗风控的方案。
3. **不做破坏性系统操作**：脚本不会在未说明的情况下擅自修改注册表、全局禁用网络协议或重装网卡驱动。
4. **客观陈述**：对服务限制和风控告警仅陈述技术事实与官方公开策略。
