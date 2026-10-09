<div align="center">

# ACME

**证书签发、部署与自动续期**

基于官方 acme.sh 的轻量管理工具。

[![Checks](https://github.com/passeway/acme/actions/workflows/check.yml/badge.svg)](https://github.com/passeway/acme/actions/workflows/check.yml)
![Shell](https://img.shields.io/badge/Shell-Bash-202938?style=flat-square)
![Systems](https://img.shields.io/badge/Linux-systemd%20%7C%20OpenRC-202938?style=flat-square)

[快速开始](#快速开始) · [验证方式](#验证方式) · [自动续期](#自动续期) · [升级与迁移](#升级与迁移)

</div>

---

## 概览

用一个交互菜单完成日常证书管理。签发和续期交给 [acme.sh](https://github.com/acmesh-official/acme.sh)，本项目负责系统依赖、输入检查、证书部署与任务调度。

- **两种验证方式**：HTTP-01 独立验证、Cloudflare DNS-01。
- **单域名与泛域名**：默认使用 ECDSA P-256；泛域名证书同时覆盖根域名。
- **按需自动续期**：每天检查，使用 acme.sh 自身的续期判断。
- **可靠部署**：检查有效期、SAN 域名和公私钥匹配；部署失败可恢复原文件。
- **兼容已有安装**：沿用原证书路径，迁移旧版定时任务。

## 快速开始

以 root 用户运行。已有证书的服务器也可以直接使用新管理脚本。

### Debian / Ubuntu / RHEL 系

确保已安装 Bash、curl 和系统 CA 证书，然后执行：

```bash
curl -fL --proto '=https' --proto-redir '=https' \
  https://raw.githubusercontent.com/passeway/acme/main/acme.sh -o acme-manager.sh &&
bash acme-manager.sh
```

### Alpine Linux

```sh
apk add --no-cache bash curl ca-certificates
curl -fL --proto '=https' --proto-redir '=https' \
  https://raw.githubusercontent.com/passeway/acme/main/acme.sh -o acme-manager.sh &&
bash acme-manager.sh
```

首次运行选择 **1** 安装客户端与续期任务，再选择证书申请方式。下载失败时不会继续运行。

原有 HTTPS 入口 [acme-red-eight.vercel.app](https://acme-red-eight.vercel.app/) 继续重定向到仓库主分支脚本。

## 系统支持

| 系统 | 包管理器 | 服务管理 | 定时服务 |
|---|---|---|---|
| Debian / Ubuntu | APT | systemd | cron |
| Rocky / AlmaLinux / RHEL / Fedora 等 | DNF / YUM | systemd | crond |
| Alpine | APK | OpenRC | BusyBox crond |

Alpine 使用 `busybox-openrc`，不依赖旧的 `busybox-initscripts` 包。脚本没有架构专用二进制，依赖使用发行版软件源提供的版本。

需要运行中的 systemd 或 OpenRC。普通 Docker 容器没有完整的 init 环境时，脚本会明确提示自动续期未启用。

## 管理菜单

| 选项 | 操作 |
|---|---|
| 1 | 安装 / 修复 acme.sh、依赖和自动续期 |
| 2 | 卸载客户端，保留证书与账户资料 |
| 3 | 申请单域名证书：HTTP / 80 |
| 4 | 申请单域名证书：Cloudflare DNS |
| 5 | 申请泛域名证书：Cloudflare DNS |
| 6 | 查看证书及续期信息 |
| 7 | 撤销证书并停止续期 |
| 8 | 立即执行一次正常续期检查 |
| 9 | 切换之后新申请使用的 CA |
| 0 | 退出 |

菜单支持连续操作。新安装默认使用 Let's Encrypt，也可以切换到 ZeroSSL；ZeroSSL 账户可能需要邮箱或 EAB 信息。已有证书继续使用各自记录的 CA。

## 验证方式

### HTTP-01

适用于公网 TCP 80 可访问、当前没有其他程序占用该端口的服务器。

1. 将域名的 A / AAAA 记录指向服务器，检查每条记录均可访问。
2. 放行安全组和防火墙的 TCP 80。
3. 选择菜单 **3**，输入域名与 IPv4 / IPv6 监听方式。

验证失败时保留已有部署文件。检测到端口占用时直接提示；脚本不会结束 Nginx、Caddy 等进程，也不会修改 WARP 或防火墙。

**HTTP 模式每次续期仍需要 TCP 80 可用。** 如果该端口长期由网站占用，建议选择 DNS 验证。

### Cloudflare DNS-01

适用于域名托管在 Cloudflare 的场景，不需要开放入站验证端口，也不要求域名解析到此服务器。

在 [Cloudflare API Tokens](https://dash.cloudflare.com/profile/api-tokens) 创建 Token：

| 项目 | 设置 |
|---|---|
| 权限 | Zone → DNS → Edit |
| 区域资源 | 仅包含需要签发证书的 Zone |
| Zone ID | 对应域名概览页中的 32 位 ID |

本脚本要求明确提供 Zone ID。若设置了 Token 的来源 IP 限制，需允许这台服务器的出口地址。

选择菜单 **4** 或 **5**，输入域名、API Token 和 Zone ID。Token 输入不回显，不通过命令行参数传递；实际使用过的凭据由官方 acme.sh 保存，供之后续期使用。

已有安装可以选择“复用已保存的凭据”，兼容原先保存的 Global API Key。新的配置优先使用限定 Zone 的 API Token。权限和保存行为详见[官方 DNS API 文档](https://github.com/acmesh-official/acme.sh/wiki/dnsapi#1-cloudflare-option)。

泛域名模式输入 `example.com`，申请结果覆盖 `example.com` 与 `*.example.com`。

## 证书部署

默认路径与旧版一致：

| 内容 | 路径 |
|---|---|
| 完整证书链 | `/root/cert/example.com.crt` |
| 私钥 | `/root/cert/example.com.key` |
| acme.sh 客户端、账户及续期配置 | `/root/.acme.sh/` |
| 迁移与失败恢复备份 | `/var/lib/acme-manager/` |
| 自动续期日志 | `/var/log/acme-manager.log` |

私钥使用 `0600` 权限，证书目录使用 `0700`。服务以非 root 身份读取证书时，应通过官方 `--install-cert` 将证书安装到该服务可读取的专用目录，并设置适当的所有权；不要开放整个 `/root`。

申请时可以填写续期后的服务重载命令，例如：

```bash
# systemd
nginx -t && systemctl reload nginx

# Alpine / OpenRC
nginx -t && rc-service nginx reload
```

已有证书留空时保留原重载命令，输入 `none` 清除。首次留空表示仅更新文件。重载命令由 root 执行，请填写你实际使用的服务命令。

部署前验证证书有效期、SAN 和公私钥匹配。签发失败不会继续部署；部署或重载失败时恢复原文件并报告失败。若重载命令包含多个动作且部分成功，仍需检查服务当前加载的证书。

## 自动续期

root crontab 每天 **03:17（服务器时区）**运行：

```text
17 3 * * * /usr/local/libexec/acme-manager-renew # passeway-acme-renew
```

该入口调用普通 `acme.sh --cron`，不强制签发。自动续期与菜单操作共用操作锁，避免并发改写证书。日志超过 1 MiB 时保留一个轮转副本。

```bash
# 查看计划和最近日志
crontab -l
tail -n 100 /var/log/acme-manager.log

# 手动执行与定时任务相同的检查
/usr/local/libexec/acme-manager-renew
```

## 升级与迁移

下载新管理脚本后，选择菜单 **1**：

- 保留已有 acme.sh 版本、账户资料及证书；首次安装从官方最新正式版获取客户端。
- 兼容旧版以 `*.example.com` 为 Main_Domain 的泛域名配置，沿用原部署路径；发现同名根域名与旧泛域名两套配置时提示先核对，避免相互覆盖。
- 备份并替换旧版写入的每日强制续期任务，同时识别官方默认续期任务，避免重复调度。
- 仅匹配当前 `/root/.acme.sh` 的已知任务；其他目录和其他程序的定时任务保持原样。
- 检测到同一目录的自定义续期命令时暂停迁移，先确认其钩子和调度方式。
- 备份并移除旧版在默认 `account.conf` 保存的 `HTTPS_INSECURE` 设置，恢复 HTTPS 校验。

手动修改了 `ACCOUNT_CONF_PATH`、账户目录或调度方式的高级安装，需要先核对自定义配置。迁移范围以本项目默认布局为准。

客户端自身升级可使用官方命令：

```bash
/root/.acme.sh/acme.sh --upgrade
```

菜单 **2** 会停止管理的续期任务并卸载客户端，保留证书、私钥及账户配置，便于重新安装恢复。菜单 **7** 是向 CA 撤销证书的操作，需要再次输入完整证书名称确认。

## 验证范围

CI 覆盖 Debian、Ubuntu、Alpine、Rocky Linux 的依赖安装和回归检查，包括：

- 域名输入、通配符参数、凭据传递与失败中断。
- 旧任务迁移、重复运行、读取 crontab 失败时的保护。
- 真实 OpenSSL 证书校验、部署失败恢复及续期锁。
- 官方 acme.sh 的离线安装、证书部署与重载钩子。

CI 不申请生产证书，也不调用 Cloudflare API。发布后仍需在真实 VPS 上验证一次签发、续期重载和重启后的 cron 自启；容器检查不替代公网 DNS、防火墙或 CA 验证。

## 上游

本项目提供中文管理入口。ACME 协议、DNS 插件和实际签发流程来自 [acmesh-official/acme.sh](https://github.com/acmesh-official/acme.sh)，相关代码及许可归上游项目所有。
