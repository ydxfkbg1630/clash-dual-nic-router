# Clash Dual NIC Router

让国内流量走网线，让国外流量通过 Wi-Fi 连接现有代理。

适用于 **Windows + Clash Verge Rev + Mihomo**。项目提供一个全局扩展脚本，以及生成、安装和恢复脚本。网卡名称和代理节点可配置，运行时由 Clash Verge 接管应用流量。

## 工作方式

| 流量 | 出口 |
| --- | --- |
| 中国大陆域名 / IP | Ethernet → DIRECT |
| 局域网和本地地址 | DIRECT，结合系统路由访问 |
| 其他地址 | Wi-Fi → 已有代理节点 |

脚本设置全局 `interface-name` 为国内网卡，给代理节点设置国外网卡；通过 GeoSite / GeoIP 分类，最终规则落到 `Overseas via Wi-Fi` 策略组。默认启用 TUN、自动路由和 fake-IP DNS。

**应用后，原来的自定义规则列表将由国内/国外分流规则整体替换。** 现有代理节点参数和其他策略组继续保留；国内、国外的含义取决于本机 GeoSite / GeoIP 数据版本。网卡同时保持连接，代理节点通过 Wi-Fi 网络可以正常访问。

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

命令输出生成的 `Script.js` 路径。打开 Clash Verge 的订阅页面，进入**全局扩展脚本**，粘贴生成文件内容并保存。随后选择**规则模式**并开启 **TUN**。在代理页面的 `Overseas via Wi-Fi` 策略组中选择可用节点。

要指定默认节点，追加 `-PreferredProxy '你的节点名称'`；默认采用配置中的首个可用节点。此参数精确匹配本地代理名称，provider 用户可在组中选择订阅节点。

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
| `preferredProxy` | 空字符串 | 默认节点名称；空值使用首个本地节点 |
| `tun` | `true` | 生成配置中的 TUN 开关；客户端开关同步设置 |
| `extraDirectCidrs` | `[]` | 额外直连网段，例如自建 VPN 网段 |

IPv6 设置继承现有配置。使用 IPv6 直连时，国内网卡需要相应 IPv6 连通性。

Provider 通过 `override.interface-name` 绑定国外网卡。带 `override-expr` 或静态 `dialer-proxy` 的配置会提示先整理链式设置。远程 provider 节点内容在扩展脚本执行阶段由内核另行加载，因此使用普通单跳 provider 节点，并在运行配置中核对其出口。自定义 DNS 上游和其他 DNS 字段保留，缺省上游为 `119.29.29.29`、`223.5.5.5`。

## 验证实际出口

在 Clash Verge 连接页面查看国内站点命中 `DIRECT`、国外站点命中 `Overseas via Wi-Fi`。Windows 的物理连接可以这样查看：

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

A configurable Clash Verge Rev enhancement script for Windows dual-NIC routing: China traffic uses Ethernet directly, while overseas traffic reaches existing proxy nodes over Wi-Fi. Set adapter names in `OPTIONS`, save the script in Clash Verge's global script editor, select Rule mode, and enable TUN. PowerShell helpers generate/install the script and restore backups. Existing routing rules are replaced by the country split; node credentials remain in the local Clash configuration. Apache-2.0 licensed.
