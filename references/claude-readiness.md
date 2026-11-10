# Claude 可用性判读（L3 后半 / L4）

## 目标端点

| 端点 | 用途 | 正常响应 | 异常含义 |
|---|---|---|---|
| `https://claude.ai` | Web 入口 | `200` / `30x` | `403` 地区或风控；`000` 网络不通 |
| `https://api.anthropic.com/v1/messages` | API | 无 key 时 `401`；参数不对 `400` | `403` 地区/策略；超时网络 |
| `https://assets-proxy.anthropic.com` | 前端资源代理 | 任意 HTTP 状态 | 无响应 = DNS/TCP/TLS 问题 |
| `https://www.google.com/generate_204` | 通用连通基线 | `204` | 非 204 = 代理链路有问题 |

只测 `claude.ai` 不够：页面能开不代表 API 通，流式请求可能走 `assets-proxy`。

## 状态码语义

| 状态 | 网络层结论 | 下一步 |
|---|---|---|
| `204`（google） | 代理链路可用 | 继续 L4 |
| `401`（api） | TCP/TLS/HTTP 全通，只缺鉴权 | 网络 PASS |
| `400`（api） | 参数问题，网络通 | 网络 PASS |
| `403` | 已到服务端，被地区/策略/风控拦截 | 读响应体，进入 L4 判断 |
| `429` | 触发限流 | 账号/频率问题，不是网络 |
| `5xx` | 服务端异常 | 等待或换时段 |
| `000` / 超时 | 没建立连接 | 回 L1/L2 |
| 证书错误 | TLS 被破坏或节点劫持 | 换节点，停止登录 |

### 403 时抓响应体

```powershell
curl.exe -s -m 15 -X POST https://api.anthropic.com/v1/messages -H "content-type: application/json" -d "{}"
```

| 响应体特征 | 含义 | 处理 |
|---|---|---|
| `authentication_error` / `invalid x-api-key` | 鉴权缺失（通常伴随 `401`） | 网络正常 |
| `invalid_request_error` | 请求体参数缺失（通常伴随 `400`） | 网络正常 |
| `permission_error` / `forbidden` | 权限或策略限制（`403`） | 查账号/组织权限或地区策略 |
| `unsupported_country` / `Request not allowed` | 地区限制（`403`） | 见下方“地区边界” |
| Cloudflare HTML (`Just a moment...` / `cf-chl`) | 站点风控 / 人机验证（`403`） | 账号/浏览器侧处理，勿反复改系统网络 |
| `rate_limit_error` | 触发限流（`429`） | 降低频率或换时段 |

## 三种客户端路径

| 客户端 | 认什么代理 | 常见漏配 |
|---|---|---|
| 浏览器 | 系统代理 / TUN | DoH 绕过、IPv6 绕过、后台进程缓存旧配置 |
| Claude Code CLI | `HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY` 环境变量，或 TUN | 只开了系统代理；`NO_PROXY` 包含目标域名；变量只在旧终端生效 |
| Claude 桌面客户端 | 系统代理 / TUN | 改完配置没有完全退出重启（托盘仍在） |

CLI 验证：

```powershell
$env:HTTPS_PROXY="http://127.0.0.1:7890"
curl.exe -s -m 10 https://ip.sb
```

端口按实际混合端口填写。`setx` 只影响新开的终端。

## 出口质量（不是硬门槛）

```powershell
curl.exe -s -m 10 https://ipinfo.io/json
```

关注字段：

- `country`：是否符合预期地区。
- `org`：含 `hosting` / `cloud` / `vps` / `datacenter` → 机房 IP；住宅 IP 的风控通常更宽松。
- 连续两次查询是否同一个 IP：频繁跳变会导致登录态失效。

机房 IP **不等于不能用**，只意味着更容易触发验证。这是节点属性，本机无法修改，换节点/机场是唯一杠杆。不要为此反复改 DNS、浏览器或系统设置。

## 地区边界（必须遵守）

- 若服务在你所在地区不受支持，本 skill 只负责告诉你“这是地区限制，不是网络配置问题”。
- **不提供**伪装地区、伪造指纹、规避风控或绕过服务条款的方法。
- 合规路径：使用官方支持地区的访问方式，或使用官方明确允许的访问渠道。
- 涉及封号风险时，只陈述事实与官方政策，不承诺“按这个做就不会被封”。

## L4 通过清单

- [ ] L0–L3 全部 PASS
- [ ] `api.anthropic.com` 返回 `401/400`（而非 `403` 或超时）
- [ ] 连续两次出口 IP 一致
- [ ] 浏览器 DoH 关闭、无公网 IPv6 绕过、WebRTC 无泄漏
- [ ] 目标客户端走的是它能识别的代理路径
- [ ] 没有 `403/429/验证码` 等账号侧信号

前五项是环境条件，最后一项是账号条件。两者混在一起时，先证明前五项通过，再谈账号。
