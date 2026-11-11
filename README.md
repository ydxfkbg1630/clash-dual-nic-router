# Clash Dual NIC Router

让国内流量走网线，让国外流量通过 Wi-Fi 连接现有代理。

适用于 **Windows + Clash Verge Rev + Mihomo**。项目提供一个全局扩展脚本，以及生成、安装和恢复脚本。网卡名称和代理节点可配置，运行时由 Clash Verge 接管应用流量。

## 工作方式

| 流量 | 出口 |
| --- | --- |
| 校园 Portal、DNS、网关和自定义排除地址 | 域名直连绑定国内网卡；明确 IP 绕过 TUN，由系统路由选择出口 |
| 原订阅中的应用、广告、站点策略 | 按原规则顺序执行；直连出口为网线，代理出口为 Wi-Fi |
| 原规则覆盖以外的地址 | 中国大陆直连网线，其余使用 Wi-Fi 代理 |

脚本设置全局 `interface-name` 为国内网卡，给代理节点设置国外网卡。默认保留原规则顺序与动作，包括原有 `MATCH`；在原配置缺少最终规则时补充 GeoSite / GeoIP 分类和 `Overseas via Wi-Fi` 兜底。默认启用 TUN、自动路由和 fake-IP DNS。

**v1.1.0 默认保留原有规则、广告拦截、分应用和指定节点策略。** 明确配置的校园直连规则与私网规则优先，其后执行原规则。原订阅显式指定的跨区域例外也继续生效，例如某国外站点指定直连时仍走网线。需要严格按国内/国外整体分流时，显式设置 `ruleMode: 'replace'` 或 `-RuleMode replace`，这会整体替换原规则列表。

从 v1.0.0 升级时，请在 Clash Verge 从原订阅重新生成运行配置；v1.1.0 会读取订阅里完整的规则。安装后的当前运行 YAML 可能仍含旧版简化规则，原订阅文件或先前备份是恢复来源。

## 准备

- Windows 10/11，已安装并运行 Clash Verge Rev。
- 两张已连接网卡，以及 Clash Verge 中可用的代理配置。
- 本机 GeoSite / GeoIP 数据包含 `private` 和 `cn`，可在 Clash Verge 中更新地理数据。
- TUN 使用 Clash Verge 的服务模式或管理员权限。
- 使用一个客户端作为 TUN / DNS 入口，其他客户端按需关闭相应接管功能。

使用脚本本身只需要 Clash Verge。PowerShell 用于生成与安装，Node.js 20+ 用于开发测试。

## 快速使用

下载本仓库，进入目录，在 PowerShell 中列出网卡：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Install-Routing.ps1 -ListAdapters
```

用列表中的实际名称生成配置。例如国内网卡名为 `以太网`，国外网卡名为 `WLAN 2`：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Install-Routing.ps1 `
  -DomesticInterface '以太网' -OverseasInterface 'WLAN 2'
```

命令输出生成的 `Script.js` 路径。打开 Clash Verge 的订阅页面，进入**全局扩展脚本**，粘贴生成文件内容并保存。随后选择**规则模式**并开启 **TUN**。在代理页面选择原订阅策略组的节点；当流量使用新增兜底时，在 `Overseas via Wi-Fi` 策略组中选择节点。

要指定新增兜底组的默认节点，追加 `-PreferredProxy '你的节点名称'`；默认采用配置中的首个可用节点。此参数精确匹配本地代理名称，provider 用户可在组中选择订阅节点。保留模式中，原有策略组和原 `MATCH` 的节点选择仍在各自组中设置。

### 文件安装与备份

添加 `-Install` 可把脚本安装到 Clash Verge 配置目录，同时备份原脚本：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Install-Routing.ps1 `
  -DomesticInterface '以太网' -OverseasInterface 'WLAN 2' -Install
```

默认目录为 `%APPDATA%\io.github.clash-verge-rev.clash-verge-rev`；便携安装使用 `-ConfigDirectory '你的配置目录'`。已有自定义扩展时，先查看其内容，再追加 `-ReplaceExisting` 执行替换。备份和生成文件放在 `%LOCALAPPDATA%\clash-dual-nic-router\时间戳`。

安装后，在 Clash Verge 打开全局扩展脚本并保存，让客户端重新生成运行配置，再选择规则模式并开启 TUN。安装脚本仅写全局扩展文件，模式和 TUN 开关由客户端保存。

### 恢复

用安装命令输出的备份目录恢复：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Restore-Routing.ps1 `
  -BackupDirectory "$env:LOCALAPPDATA\clash-dual-nic-router\安装时输出的目录名"
```

随后在 Clash Verge 保存全局扩展脚本，重载配置，并将模式、TUN 开关设回自己的原有偏好。恢复前会保存当前脚本；安装后发生过编辑时，先查看变更，再用 `-Force` 恢复。

## 手动配置

直接编辑 `split-routing.js` 顶部的 `OPTIONS`，再粘贴到全局扩展脚本：

| 参数 | 默认值 | 用途 |
| --- | --- | --- |
| `domesticInterface` | `Ethernet` | 国内直连网卡，填 Windows 中的实际名称 |
| `overseasInterface` | `Wi-Fi` | 代理连接使用的网卡 |
| `preferredProxy` | 空字符串 | 新增兜底组的默认节点；空值使用首个本地节点 |
| `tun` | `true` | 生成配置中的 TUN 开关；客户端开关同步设置 |
| `ruleMode` | `preserve` | 保留原规则；`replace` 为显式整体分流模式 |
| `proxyIpVersion` | `ipv4` | 代理服务器连接使用 IPv4；支持 `dual`、`ipv6`、`ipv4-prefer`、`ipv6-prefer` |
| `extraDirectCidrs` | `[]` | 校园 Portal / DNS / VPN 的明确 IP 网段，同时加入 TUN 排除列表 |
| `extraDirectDomains` | `[]` | Portal 域名及其子域名：优先直连并使用真实 DNS 地址 |

全局 IPv6 与国内直连设置继承现有配置；远端代理节点及 provider 默认使用 `ip-version: ipv4`，避免热点缺少 IPv6 路由时选中 AAAA。IPv6-only 节点需要将 `proxyIpVersion` 改为 `ipv6` 或其他合适模式，并确认国外网卡 IPv6 连通性。实际 TCP 源地址仍应对应所选国外网卡。

Provider 通过 `override.interface-name` 绑定国外网卡。带 `override-expr` 或静态 `dialer-proxy` 的配置会提示先整理链式设置。远程 provider 节点内容在扩展脚本执行阶段由内核另行加载，因此使用普通单跳 provider 节点，并在运行配置中核对其出口。自定义 DNS 上游和其他 DNS 字段保留，缺省上游为 `119.29.29.29`、`223.5.5.5`。

## 校园认证与 DNS

TUN 排除仅负责让流量交给系统路由；请保持国内网卡对应网关可达这些地址，并按实际源地址验证出口。安装脚本默认读取**国内网卡**的 DNS 和默认网关，将这些明确地址加入 `extraDirectCidrs`；`-SkipNetworkDiscovery` 可切换为全部手动配置。选择校园 Portal 时以学校提供的网址/IP 为准。Portal 的公共地址和校园 DNS 可这样添加（下列为文档示例）：

```powershell
.\scripts\Install-Routing.ps1 `
  -DomesticInterface '以太网' -OverseasInterface 'WLAN 2' `
  -ExtraDirectDomains 'portal.example.edu' `
  -ExtraDirectCidrs @('192.0.2.10/32', '198.51.100.53/32') -Install
```

使用 PowerShell 的 `&` 或上述直接脚本调用来传递数组参数。域名会加入优先直连和 fake-IP 例外；其对应 IP 通过 `extraDirectCidrs` 加入 TUN `route-exclude-address`。填写 Portal 域名时也添加学校公布的实际 IP；单靠域名规则的流量仍由 TUN 收到后直连。学校改动认证地址后同步更新这些参数。

DNS 原有 nameserver、fallback 等字段保留。`fake-ip-filter-mode: blacklist` 与 `rule` 支持合并 Portal 例外；whitelist 配置会提示先调整过滤模式，便于明确真实地址的解析方式。

## 验证实际出口

在 Clash Verge 连接页面查看国内站点最终经过 `DIRECT`、国外代理站点最终经过订阅节点（原策略组或 `Overseas via Wi-Fi`）。Windows 的物理连接可以这样查看：

```powershell
Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceAlias, IPAddress
Get-NetTCPConnection -State Established |
  Where-Object OwningProcess -In (Get-Process verge-mihomo).Id |
  Select-Object LocalAddress, RemoteAddress, RemotePort
```

国内直连 TCP 的 `LocalAddress` 应对应国内网卡，代理服务器 TCP 的 `LocalAddress` 应对应国外网卡。Hysteria2 / TUIC 等 UDP 节点需要结合客户端日志或抓包核对。

项目源自一次 Windows 双网卡实机配置：国内、国外网页均成功返回 HTTP 200，已通过物理套接字源地址核实两种出口。仓库自动测试覆盖配置转换与安装恢复行为；使用者机器的网关、订阅和地理数据由本机验证。

## 开发

```powershell
npm ci
npm run check
npm test
powershell -ExecutionPolicy Bypass -File .\tests\installer.test.ps1
```

项目运行依赖为零。CI 在 Windows / Linux、Node.js 22 / 24 上测试配置转换，Windows 上测试安装和恢复。

贡献请参阅 [CONTRIBUTING.md](CONTRIBUTING.md)，安全问题请参阅 [SECURITY.md](SECURITY.md)。

## 许可与来源

本仓库代码采用 [Apache-2.0](LICENSE)，Copyright 2026 ydxfkbg1630。

Clash Verge Rev、Mihomo 和 GeoSite / GeoIP 数据由各自项目维护，许可分别适用。本仓库发行内容为配置脚本与文档；代理订阅、账号和运行数据由使用者本机管理。

参考：[Mihomo 出站接口](https://wiki.metacubex.one/config/general/)、[代理节点](https://wiki.metacubex.one/config/proxies/)、[Provider](https://wiki.metacubex.one/config/proxy-providers/)、[TUN](https://wiki.metacubex.one/config/inbound/tun/)。

## English overview

A configurable Clash Verge Rev enhancement script for Windows dual-NIC routing: China traffic uses Ethernet directly, while overseas traffic reaches existing proxy nodes over Wi-Fi. Set adapter names in `OPTIONS`, save the script in Clash Verge's global script editor, select Rule mode, and enable TUN. PowerShell helpers generate/install the script and restore backups. Version 1.1 preserves existing rules by default, including ad blocking, application policies, and the original MATCH. Explicit policies take precedence over geographic fallback. Opt into `ruleMode: "replace"` for a full country split. Proxy transports default to IPv4; domestic IPv6 remains inherited. Campus domains receive real-IP DNS exceptions, and explicit campus/DNS/gateway CIDRs bypass TUN. Node credentials remain in the local Clash configuration. Apache-2.0 licensed.
