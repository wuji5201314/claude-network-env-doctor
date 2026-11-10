# Progressive network environment doctor (L0-L4). Read-only.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File doctor.ps1 [-NoClaude] [-BaselineUrl https://example.com/]
param(
  [switch]$NoClaude,
  [string]$BaselineUrl = 'https://example.com/'
)

$ErrorActionPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$script:rows = New-Object System.Collections.ArrayList

function Line($level, $item, $status, $detail) {
  [void]$script:rows.Add([pscustomobject]@{ Level = $level; Item = $item; Status = $status; Detail = $detail })
  "{0}  {1,-30} {2,-6} {3}" -f $level, $item, $status, $detail
}
function Head($text) { "`n=== $text ===" }

function Resolve-HostIps([string]$HostName) {
  $records = @(Resolve-DnsName -Name $HostName -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress })
  if ($records.Count -gt 0) {
    return @($records | Select-Object -ExpandProperty IPAddress -Unique)
  }
  # Fallback to nslookup parsing (skip the first Server/Address header block)
  $raw = (& nslookup $HostName 2>&1 | Out-String)
  if ($raw -match 'Non-existent|not find|timed out|Server failed|找不到|超时') { return @() }
  $blocks = @($raw -split "(?m)^(?:Name|名称)\s*:")
  if ($blocks.Count -lt 2) { return @() }
  $answerBlock = $blocks[1..($blocks.Count - 1)] -join "`n"
  $ips = @([regex]::Matches($answerBlock, '\b(?:\d{1,3}\.){3}\d{1,3}\b') | ForEach-Object { $_.Value })
  return @($ips | Select-Object -Unique)
}

function Normalize-ProxyUrl([string]$RawProxy) {
  if (-not $RawProxy) { return $null }
  $val = $RawProxy.Trim()
  if ($val -match 'https?=([^;]+)') { $val = $Matches[1].Trim() }
  elseif ($val -match 'socks=([^;]+)') { $val = 'socks5://' + $Matches[1].Trim() }
  if ($val -notmatch '^[a-zA-Z0-9]+://') { $val = "http://$val" }
  return $val
}

function Describe-CurlFailure([int]$ExitCode) {
  switch ($ExitCode) {
    6  { return 'DNS resolve failed (curl exit 6)' }
    7  { return 'TCP connect failed/refused (curl exit 7)' }
    28 { return 'connection timed out (curl exit 28)' }
    35 { return 'TLS/SSL handshake failed (curl exit 35)' }
    60 { return 'TLS certificate verification failed (curl exit 60)' }
    default { return "no HTTP response (curl exit $ExitCode)" }
  }
}

function HttpProbe {
  param(
    [string]$Url,
    [string]$Method = 'GET',
    [string]$Body = $null,
    [int]$Timeout = 15,
    [string]$ProxyUrl = $null,
    [switch]$NoProxy
  )
  $curlArgs = @('-s', '-m', "$Timeout", '-X', $Method, '-w', "`n%{http_code}")
  if ($NoProxy) { $curlArgs += @('--noproxy', '*') }
  elseif ($ProxyUrl) { $curlArgs += @('-x', $ProxyUrl) }
  if ($Body) { $curlArgs += @('-H', 'content-type: application/json', '-d', $Body) }
  $curlArgs += $Url
  $raw = (& curl.exe @curlArgs 2>$null | Out-String)
  $exitCode = $LASTEXITCODE
  $lines = @($raw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
  $code = '000'
  $bodyText = ''
  if ($lines.Count -gt 0) {
    $code = $lines[-1].Trim()
    if ($code -notmatch '^\d{3}$') { $code = '000' }
    if ($lines.Count -gt 1) { $bodyText = (@($lines[0..($lines.Count - 2)]) -join ' ').Trim() }
  }
  if ($bodyText.Length -gt 240) { $bodyText = $bodyText.Substring(0, 240) + '...' }
  [pscustomobject]@{
    Code     = $code
    Body     = $bodyText
    ExitCode = $exitCode
    FailReason = $(if ($code -eq '000') { Describe-CurlFailure $exitCode } else { '' })
  }
}

"=== Claude Network Environment Doctor ==="
"time=" + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
if ($NoClaude) { "mode=skip Claude endpoints" }

Head 'L0 basic connectivity'
$routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric, InterfaceMetric)
$physRoutes = @($routes | Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' -and $_.NextHop -notmatch '^198\.18\.' })
if ($physRoutes.Count -gt 0) {
  $routeDetail = "count=$($routes.Count) physical_next_hop=$($physRoutes[0].NextHop)"
  if ($routes[0].NextHop -ne $physRoutes[0].NextHop) { $routeDetail += " primary_route=$($routes[0].NextHop)" }
  Line 'L0' 'default route' 'PASS' $routeDetail
} elseif ($routes.Count -gt 0) {
  Line 'L0' 'default route' 'WARN' "only virtual/TUN default route found (next_hop=$($routes[0].NextHop)); verify physical Wi-Fi/Ethernet"
} else {
  Line 'L0' 'default route' 'FAIL' 'none; enable the adapter / renew DHCP first'
}

$baselineHost = ([uri]$BaselineUrl).DnsSafeHost
$baselineIps = @(Resolve-HostIps $baselineHost)
if ($baselineIps.Count -gt 0) {
  Line 'L0' 'dns resolve (baseline)' 'PASS' ("$baselineHost -> " + ($baselineIps -join ', '))
} else {
  Line 'L0' 'dns resolve (baseline)' 'FAIL' "$baselineHost did not resolve; if this site is blocked locally, rerun with -BaselineUrl pointing to a known reachable site"
}

$baseline = HttpProbe -Url $BaselineUrl -Timeout 8
if ($baseline.Code -eq '000' -and ($env:HTTP_PROXY -or $env:HTTPS_PROXY -or $env:ALL_PROXY)) {
  $baselineDirect = HttpProbe -Url $BaselineUrl -Timeout 8 -NoProxy
  if ($baselineDirect.Code -match '^(2|3)\d\d$') {
    Line 'L0' 'baseline https' 'WARN' "$baselineHost direct=$($baselineDirect.Code), but failed via env proxy ($($baseline.FailReason))"
  } else {
    Line 'L0' 'baseline https' 'FAIL' "$baselineHost=$($baseline.Code) ($($baseline.FailReason))"
  }
} elseif ($baseline.Code -match '^(2|3)\d\d$') {
  Line 'L0' 'baseline https' 'PASS' "$baselineHost=$($baseline.Code)"
} else {
  Line 'L0' 'baseline https' 'FAIL' "$baselineHost=$($baseline.Code) ($($baseline.FailReason)); if blocked locally, rerun with -BaselineUrl"
}

Head 'L1 proxy path'
$allProxyProcs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
  $_.ProcessName -match 'verge-mihomo|mihomo|clash|FlClash|sing-box|v2ray|xray|shadowsocks|warp|nekoray|nekobox|hiddify|karing|proxifier'
} | Select-Object -ExpandProperty ProcessName -Unique)
$helperProcs = @($allProxyProcs | Where-Object { $_ -match 'service|helper' })
$coreProcs = @($allProxyProcs | Where-Object { $_ -notmatch 'service|helper' })

if ($coreProcs.Count -gt 0) {
  $procDetail = ($coreProcs -join ', ')
  if ($helperProcs.Count -gt 0) { $procDetail += " (services: $($helperProcs -join ', '))" }
  Line 'L1' 'proxy tool' 'PASS' $procDetail
} elseif ($helperProcs.Count -gt 0) {
  Line 'L1' 'proxy tool' 'WARN' "only background service running ($($helperProcs -join ', ')); main proxy client/core is not running"
} else {
  Line 'L1' 'proxy tool' 'WARN' 'none detected'
}

$inet = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$proxyEnable = (Get-ItemProperty -Path $inet -Name ProxyEnable -ErrorAction SilentlyContinue).ProxyEnable
$proxyServer = (Get-ItemProperty -Path $inet -Name ProxyServer -ErrorAction SilentlyContinue).ProxyServer
$sysProxyUrl = if ($proxyEnable -eq 1 -and $proxyServer) { Normalize-ProxyUrl $proxyServer } else { $null }

$tunAdapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
  ($_.Name -match 'Mihomo|Meta|Clash|sing|TUN|WARP|utun' -or $_.InterfaceDescription -match 'Tunnel|WinTun|Mihomo|sing|WireGuard|TAP') -and $_.Status -eq 'Up'
})
$capture = @()
if ($proxyEnable -eq 1 -and $proxyServer) { $capture += "system_proxy=$proxyServer" }
if ($tunAdapters.Count -gt 0) { $capture += 'TUN=' + (($tunAdapters | Select-Object -ExpandProperty Name) -join ',') }

$procEnvProxy = @('HTTPS_PROXY', 'HTTP_PROXY', 'ALL_PROXY') | ForEach-Object {
  $v = [Environment]::GetEnvironmentVariable($_, 'Process')
  if ($v) { "$_=$v" }
}
$userEnvProxy = (Get-ItemProperty -Path 'HKCU:\Environment' -ErrorAction SilentlyContinue).HTTP_PROXY
$userEnvHttpsProxy = (Get-ItemProperty -Path 'HKCU:\Environment' -ErrorAction SilentlyContinue).HTTPS_PROXY
if ($procEnvProxy.Count -gt 0) { $capture += "env(" + ($procEnvProxy -join ', ') + ")" }
elseif ($userEnvHttpsProxy -or $userEnvProxy) {
  $uVal = if ($userEnvHttpsProxy) { "HTTPS_PROXY=$userEnvHttpsProxy" } else { "HTTP_PROXY=$userEnvProxy" }
  $capture += "user_reg_env($uVal)"
}

if ($capture.Count -gt 0) { Line 'L1' 'capture mode' 'PASS' ($capture -join '; ') }
else { Line 'L1' 'capture mode' 'WARN' 'no system proxy, no TUN, no HTTP(S)_PROXY' }

if ($tunAdapters.Count -gt 1) {
  Line 'L1' 'multi-TUN conflict' 'WARN' ("multiple active TUN adapters (" + (($tunAdapters | Select-Object -ExpandProperty Name) -join ', ') + "); keep only one")
}

# Note: Windows curl.exe ignores WinINET system proxy unless TUN or env proxy is present.
$useExplicitSysProxy = ($null -ne $sysProxyUrl) -and ($tunAdapters.Count -eq 0) -and ($procEnvProxy.Count -eq 0)
$probeProxyArg = if ($useExplicitSysProxy) { $sysProxyUrl } else { $null }
$probeRouteNote = if ($useExplicitSysProxy) { "via -x $sysProxyUrl (curl.exe ignores WinINET by default)" } else { "ambient curl path" }

function Get-EgressIp([string]$ProxyUrl = $null) {
  foreach ($ep in @('https://ip.sb', 'https://api.ipify.org')) {
    $cArgs = @('-4', '-s', '-m', '10')
    if ($ProxyUrl) { $cArgs += @('-x', $ProxyUrl) }
    $cArgs += $ep
    $out = (& curl.exe @cArgs 2>&1 | Out-String).Trim()
    $ip = ($out -split "`r?`n" | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -First 1)
    if ($ip) { return $ip }
  }
  return $null
}

$egress = Get-EgressIp -ProxyUrl $probeProxyArg
if ($egress) {
  Line 'L1' 'curl egress ipv4' 'INFO' "$egress ($probeRouteNote; verify target client uses same route)"
} else {
  Line 'L1' 'egress ipv4' 'FAIL' "no response from ip.sb / api.ipify.org ($probeRouteNote)"
}

if ($egress) {
  $geoArgs = @('-s', '-m', '10')
  if ($probeProxyArg) { $geoArgs += @('-x', $probeProxyArg) }
  $geoArgs += "https://ipinfo.io/$egress/json"
  $geoRaw = (& curl.exe @geoArgs 2>&1 | Out-String).Trim()
  $geo = $null
  try { $geo = $geoRaw | ConvertFrom-Json } catch {}
  if ($geo -and $geo.country) {
    $org = [string]$geo.org
    if ($org -match 'hosting|cloud|vps|datacenter|server') { Line 'L1' 'egress geo' 'WARN' ("$($geo.country) / $org (hosting range)") }
    else { Line 'L1' 'egress geo' 'INFO' ("$($geo.country) / $org") }
  }
}

Head 'L2 dns and leaks'
$claudeIps = @(Resolve-HostIps 'claude.ai')
if ($claudeIps -match '^198\.18\.') {
  Line 'L2' 'dns for claude.ai' 'PASS' ("$($claudeIps -join ', ') (fake-ip, hijacked by TUN/DNS)")
} elseif ($claudeIps.Count -gt 0) {
  Line 'L2' 'dns for claude.ai' 'INFO' ("$($claudeIps -join ', ') (real IP; normal when not using fake-ip)")
} else {
  Line 'L2' 'dns for claude.ai' 'FAIL' 'cannot resolve claude.ai'
}

$v6 = (& curl.exe -6 -s -m 8 https://ip.sb 2>&1 | Out-String).Trim()
if ($v6 -match '^[0-9a-fA-F:]+$' -and $v6 -match ':') { Line 'L2' 'curl ipv6 egress' 'INFO' "$v6 (curl path only; compare with intended client route)" }
else { Line 'L2' 'ipv6 egress' 'PASS' 'none' }

$activeNames = @($routes | ForEach-Object { (Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue).Name } | Where-Object { $_ } | Select-Object -Unique)
$physicalActive = @($activeNames | Where-Object { $_ -notmatch '^(Mihomo|Meta|utun|Clash|sing|WARP|vEthernet|VMware)' })
$v6Bindings = @(Get-NetAdapterBinding -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue | Where-Object { $_.Enabled })
$activeHasV6 = @($v6Bindings | Where-Object { $physicalActive -contains $_.Name }).Count -gt 0
$global6 = @(Get-NetIPAddress -AddressFamily IPv6 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notmatch '^(fe80:|::1$|fc|fd)' })
if ($activeHasV6 -and $global6.Count -gt 0) { Line 'L2' 'ipv6 on active NIC' 'INFO' "non-link-local IPv6 present: $($global6[0].IPAddress) (not proof of client bypass)" }
elseif ($activeHasV6) { Line 'L2' 'ipv6 on active NIC' 'INFO' 'enabled on physical NIC but no global address' }
else { Line 'L2' 'ipv6 on active NIC' 'PASS' 'TCP/IPv6 disabled on active physical adapter' }

$browsers = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(msedge|chrome|firefox|brave)$' })
if ($browsers.Count -gt 0) {
  $grouped = ($browsers | Group-Object ProcessName | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', '
  Line 'L2' 'browser processes' 'INFO' "$grouped (kill all background processes after proxy/IPv6 changes)"
}
Line 'L2' 'browser DoH' 'MANUAL' 'must be OFF (toggle grey), not just another provider'
Line 'L2' 'WebRTC leak' 'MANUAL' 'browserleaks.com/webrtc should show No Leak'

Head 'L3 reachability'
$google = HttpProbe -Url 'https://www.google.com/generate_204' -Timeout 12 -ProxyUrl $probeProxyArg
if ($google.Code -eq '204') { Line 'L3' 'google 204' 'PASS' "204 ($probeRouteNote)" }
elseif ($google.Code -eq '000') { Line 'L3' 'google 204' 'FAIL' "$($google.FailReason) ($probeRouteNote)" }
else { Line 'L3' 'google 204' 'WARN' "unexpected code $($google.Code) ($probeRouteNote)" }

if (-not $NoClaude) {
  $claude = HttpProbe -Url 'https://claude.ai' -Timeout 15 -ProxyUrl $probeProxyArg
  switch -Regex ($claude.Code) {
    '^(2|3)\d\d$' { Line 'L3' 'claude.ai' 'PASS' $claude.Code; break }
    '^403$' {
      $cfHint = if ($claude.Body -match 'Just a moment|cf-chl|cloudflare') { ' (Cloudflare challenge)' } else { '' }
      Line 'L3' 'claude.ai' 'WARN' ("403$cfHint " + $claude.Body)
      break
    }
    '^000$' { Line 'L3' 'claude.ai' 'FAIL' $claude.FailReason; break }
    default { Line 'L3' 'claude.ai' 'INFO' $claude.Code }
  }

  $api = HttpProbe -Url 'https://api.anthropic.com/v1/messages' -Method 'POST' -Body '{}' -Timeout 15 -ProxyUrl $probeProxyArg
  switch -Regex ($api.Code) {
    '^(400|401|422)$' { Line 'L3' 'api.anthropic.com' 'PASS' "$($api.Code) (network OK, auth/params missing)"; break }
    '^403$' { Line 'L3' 'api.anthropic.com' 'WARN' ("403 " + $api.Body); break }
    '^429$' { Line 'L3' 'api.anthropic.com' 'WARN' '429 rate limited'; break }
    '^5\d\d$' { Line 'L3' 'api.anthropic.com' 'WARN' "$($api.Code) server error"; break }
    '^000$' { Line 'L3' 'api.anthropic.com' 'FAIL' $api.FailReason; break }
    default { Line 'L3' 'api.anthropic.com' 'INFO' $api.Code }
  }

  $assets = HttpProbe -Url 'https://assets-proxy.anthropic.com' -Timeout 15 -ProxyUrl $probeProxyArg
  if ($assets.Code -eq '000') { Line 'L3' 'assets-proxy' 'FAIL' $assets.FailReason }
  else { Line 'L3' 'assets-proxy' 'PASS' "http $($assets.Code)" }
}

if (-not $NoClaude) {
  Head 'L4 Claude readiness'
  if ($api) {
    if ($api.Code -eq '403' -and $api.Body -match 'unsupported_country|not available|Request not allowed|forbidden') {
      Line 'L4' 'region / policy' 'WARN' '403 suggests region or policy restriction'
      Line 'L4' 'boundary' 'INFO' 'no spoofing/evasion advice; use an officially supported region'
    } elseif ($api.Code -eq '403') {
      Line 'L4' 'region / policy' 'WARN' '403; inspect response body before changing network'
    } elseif ($api.Code -match '^(400|401|422)$') {
      Line 'L4' 'region / policy' 'PASS' 'no region block observed on API endpoint'
    } else {
      Line 'L4' 'region / policy' 'INFO' "not classified from HTTP $($api.Code); inspect endpoint result and client symptoms"
    }
  }
  if ($egress) {
    $egress2 = Get-EgressIp -ProxyUrl $probeProxyArg
    if ($egress2 -and $egress2 -eq $egress) {
      Line 'L4' 'egress stability' 'PASS' "consistent ($egress)"
    } elseif ($egress2) {
      Line 'L4' 'egress stability' 'WARN' "egress IP changed between probes ($egress -> $egress2); may cause session logout"
    }
  }
  if ($geo -and $geo.country) {
    if ([string]$geo.org -match 'hosting|cloud|vps|datacenter|server') { Line 'L4' 'exit quality' 'WARN' 'hosting IP: usable, but verification is more likely' }
    else { Line 'L4' 'exit quality' 'PASS' 'non-hosting range' }
  }
  Line 'L4' 'client path' 'MANUAL' 'browser=system proxy/TUN; CLI=HTTPS_PROXY or TUN; desktop=system proxy/TUN + full restart'
  Line 'L4' 'account signals' 'MANUAL' '403/429/captcha/login loop = account side, stop tuning network'
}

Head 'verdict'
$firstFail = $script:rows | Where-Object { $_.Status -eq 'FAIL' } | Select-Object -First 1
$warnCount = @($script:rows | Where-Object { $_.Status -eq 'WARN' }).Count
$failCount = @($script:rows | Where-Object { $_.Status -eq 'FAIL' }).Count
"fail=$failCount warn=$warnCount"
if ($firstFail) {
  "First reported FAIL: $($firstFail.Level) $($firstFail.Item) -> $($firstFail.Detail)"
  'Use this as a lead, then follow the symptom-specific decision path in SKILL.md. The snapshot continues across layers and does not prove the target client path.'
} else {
  'No FAIL signal in this snapshot; this does not prove every layer or client path is healthy.'
  if ($warnCount -gt 0) { 'Review WARN lines only when they match the reported symptom.' }
}
