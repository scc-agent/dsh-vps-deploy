# DSH VPS Deploy

这是一个可审阅、可重复的通用 Linux VPS 部署工具，固定安装 `@deepseek-ai/dsh@0.2.2-rc.1`，不是 DSH 本体。默认流程是 **原生 TLS + Tailscale Serve 私有 HTTPS**：安装器用 `openssl` 生成 10 年期自签证书，DSH 自己用 `--tls-cert`/`--tls-key` 在 `127.0.0.1:3080` 上跑 HTTPS，Serve 通过 `https+insecure://127.0.0.1:3080` 直连它，**中间没有本机代理**。因为后端本身就是 HTTPS，`DSH_PUBLIC_URL` 为 https 时 DSH 会自己给 Cookie 加 `Secure`，不需要代理补。入口仍受 tailnet ACL/设备接入控制。本流程不会启用 Funnel、开放公网端口或修改防火墙。

本仓库只提供两种模式：`serve`（原生 TLS，默认）和 `local-only`（回环 + SSH 隧道）。早先的 `dsh-web-proxy.service`（127.0.0.1:3081 校验 Host、补 Secure Cookie）已经从仓库删除；从旧版本升级时安装器会停用并移除残留的 `dsh-web-proxy.service`。

工具不包含任何域名、IP、账号、token、私钥或 API key。

## 新人前置条件

- Linux、systemd、root，Node.js `>=24.9.0` 和 npm。脚本使用 PATH 中的 `node`，不会写死某台机器的 Node 路径。
- 默认模式需要已安装并运行 Tailscale。若 CLI 不存在，脚本只在已配置官方 apt 源、且可核验为 Debian/Ubuntu 系统时接受 `DSH_TAILSCALE_INSTALL=yes`；它不会执行第三方 `curl | sh`。没有明确授权时，安装器退出并给出继续命令。
- Tailscale 必须已登录，tailnet 管理员必须启用 HTTPS/MagicDNS。手机访问前，手机也必须安装 Tailscale 并加入同一 tailnet；浏览器能看到页面不代表手机已接入。
- DSH 的模型/API 仍需在 Web GUI 的设置中配置。至少选择 DeepSeek provider、填写真实 API 模型配置，并发送一条最小消息确认 assistant 回复；Serve 不会替你配置 API。

这是私有 tailnet 入口，不是公网自动开放方案。没有中间代理：TLS 由 DSH 自己终止，Cookie 的 `Secure` 由 DSH 依据 https 的 `DSH_PUBLIC_URL` 自行下发。Funnel 与 Serve 是不同功能，本文和脚本都不会替你打开 Funnel。

## 默认安装

先做不改主机的预检：

```sh
sudo DSH_DRY_RUN=yes ./install.sh
```

默认安装会先只读检查 Tailscale：CLI 存在、`BackendState=Running`、有本机 MagicDNS 名称、Serve/HTTPS 可用、没有已有不同 handler，也没有 Funnel。之后才在独立目录安装 DSH，生成自签证书，只启动 `dsh-web.service`，并执行：

```sh
tailscale serve --bg --https=443 https+insecure://127.0.0.1:3080
```

`DSH_PUBLIC_URL` 和 `DSH_TRUSTED_HOST` 未显式提供时，会从 Tailscale 当前机器的 DNS 名称自动探测，该名称同时用作证书 SAN。可显式固定：

```sh
sudo DSH_PUBLIC_URL=https://my-machine.example.ts.net/ \
  DSH_TRUSTED_HOST=my-machine.example.ts.net ./install.sh
```

Serve 已有其他服务时安装器会退出，不会 reset、替换或重启其他服务。重复运行时，如果现有 handler 已经指向本模式的后端（`https+insecure://127.0.0.1:3080`），它会视为已配置；应用失败也不会冒充成功。从旧版本升级时，安装器会停用并移除遗留的 `dsh-web-proxy.service`（以及它占用的 3081 端口），因为原生 TLS 已经取代它。

### 安装布局与目录权限

程序、数据、工作区三者分开，agent 在自己工作区里看不到 DSH 程序文件：

| 路径 | 所有者 / 权限 | 用途 |
| --- | --- | --- |
| `/opt/dsh/app` | `root:root` `0755`（目录树全部 root 所有） | npm 装的 DSH 程序（`node_modules/@deepseek-ai/dsh`），与服务用户的 `/tmp`、工作区完全隔离 |
| `/var/lib/dsh` | `dsh:dsh` `0750` | 服务用户的数据目录（`DSH_HOME`），DSH 的 `profiles`、凭据、会话在 `/var/lib/dsh/.dsh` |
| `/var/lib/dsh/workspace` | `dsh:dsh` `0750` | DSH 默认工作区，systemd 的 `WorkingDirectory` 指这里 |
| `/etc/dsh` | `root:dsh` `0750` | 配置与自签证书（`/etc/dsh/dsh-web.env` 为 `0640`，私钥 `0640 root:dsh`） |

由此得到三条性质：

- 服务用户对 `/opt/dsh/app` 只有读和执行的权限，**不能写**，改不了自己的代码；配合 `ProtectSystem=strict` + `ReadWritePaths=/var/lib/dsh`，即使服务被攻破也无法落盘到程序目录。
- agent 的默认工作区是 `/var/lib/dsh/workspace`，不是家目录本身，所以在工作区里列不出 `.dsh` 以外的目录布局，更碰不到 `/opt/dsh/app`。
- 升级时安装器在 `/opt/dsh/.app.stage.<pid>` 装新树、原子换入、再强制 `chown -R root:root`，旧树在换入后才删。

**这条边界的真实范围（重要）**：上面挡住的是"agent 改写自己的程序"，不是"agent 拿不到 DSH 的秘密"。agent 与服务跑在同一个 `dsh` 用户下，所以它**读得到**：

- `$DSH_HOME/.dsh` 里的凭据与会话（例如 `.credentials.yaml`，`0600` 但属主就是 `dsh`）
- `/etc/dsh/tls/dsh.key`（`0640 root:dsh`，组是服务用户，可读）
- `/etc/dsh/dsh-web.env`

这是"agent 与服务同用户"的结构性结果，不是配置遗漏。真要隔离 agent 与服务自身的凭据，需要拆成两个用户再加 namespace/沙箱，是另一个量级的改造；本工具没有做，也不会暗示已经做了。

程序位置可用 `DSH_APP_ROOT`（默认 `/opt/dsh`）覆盖，工作区始终是 `$DSH_HOME/workspace`。

### 缺失、未登录或 HTTPS 未启用

错误信息会明确区分：

- 缺少 Tailscale：先从官方包源安装；仅在确认平台和 apt 源后才可显式使用 `DSH_TAILSCALE_INSTALL=yes`。
- 未登录：执行 `sudo tailscale up`，完成授权后运行错误消息中的 continue 命令。
- HTTPS/Serve 不可用：在 Tailscale 管理界面为 tailnet 启用 HTTPS，再运行 continue 命令。
- 冲突：先用 `sudo tailscale serve status --json` 审阅现有配置；本工具不会替你删除它。

非交互执行也会返回非零状态，继续命令会明确显示在 stderr。无 `sudo` 的环境请自行用等价 root 命令，不要把 token 粘进 shell 历史或工单。

## 可选模式

`DSH_TAILSCALE_MODE=serve` 是默认且推荐的私有 HTTPS 模式：自签证书 + 原生 TLS + Serve 直连 3080。

`DSH_TAILSCALE_MODE=local-only` 保持 loopback，只适合 SSH 隧道或本机访问：

```sh
sudo DSH_TAILSCALE_MODE=local-only ./install.sh
```

这个模式下 DSH 只绑 `127.0.0.1`，所以 `DSH_PUBLIC_URL` 填非回环地址（例如 `https://my-machine.example.ts.net:3082/`）时，安装器**自检探针改用回环地址**（`http://127.0.0.1:${DSH_PORT}/`；原生 TLS 下是 `https://` 并带 `--insecure` 只跳过本机自签证书校验），不会拿不可达的 public URL 去验 401/303/WS。写进 `/etc/dsh/dsh-web.env` 的 `DSH_PUBLIC_URL` 仍是用户给的真实值，只影响自检探针。同时安装器会把 `127.0.0.1` 追加进 `DSH_TRUSTED_HOST`，让 DSH 的 `/api` Host 信任栅栏接受回环探针，避免把健康服务判成 421。

结论：local-only + 非回环 `DSH_PUBLIC_URL` 时安装器退出码为 0，不再误报失败。探针地址由 `tools/probe-url.sh` 决定：`serve` 按 public URL 验（那才是浏览器的真实路径），只有 `local-only` 才走回环。

不再提供代理回退模式和自带反代的 `external-proxy` 模式。旧版本的 `dsh-web-proxy.service` 已经删除；想从旧拓扑切回来，直接重跑 `sudo ./install.sh`，残留的代理单元会被停用并移除。

也可以自己提供证书：给出 `DSH_TLS_CERT` 和 `DSH_TLS_KEY` 即跳过自签生成，仍走原生 TLS（Serve 依旧 `https+insecure://`），且 `DSH_PUBLIC_URL` 必须是 HTTPS。自签相关的可调项：`DSH_TLS_DIR`（默认 `/etc/dsh/tls`）、`DSH_TLS_KEY_TYPE`（`rsa2048` 默认 / `ecdsa`）、`DSH_TLS_DAYS`（默认 `3650`）。

通用变量：`DSH_USER`（默认 `dsh`）、`DSH_HOME`（默认 `/var/lib/dsh`，服务数据目录与工作区的父目录）、`DSH_APP_ROOT`（默认 `/opt/dsh`，程序安装在 `$DSH_APP_ROOT/app`）、`DSH_PORT`（默认 `3080`）、`DSH_ENABLE`（默认 `yes`）。DSH 的 systemd 资源上限为 `MemoryHigh=512M`、`MemoryMax=768M`、`CPUQuota=75%`、`TasksMax=128`，并启用 `NoNewPrivileges`、`PrivateDevices`、`ProtectSystem=strict`、`ProtectHome`、`ProtectKernelTunables/Modules/Logs` 和空的 `CapabilityBoundingSet`，由独立的服务用户运行。

## 认证与验证

- `tools/gen-selfsigned-cert.sh`：生成/复用自签证书。目录 `0750`、证书 `0644`、私钥 `0640` 且属主 `root`、组为 DSH 服务用户，SAN 含 MagicDNS 主机名、`localhost` 和 `127.0.0.1`；仍在有效期内且 SAN 匹配时不会重签。
- `tools/verify-ws.mjs`：对目标做一次真实 WebSocket upgrade 握手，只打印状态码，从不打印 Cookie 值。
- `tools/probe-url.sh`：决定自检探针地址。`serve` 用 `DSH_PUBLIC_URL`（浏览器真实路径），`local-only` 用回环地址；同时决定原生 TLS 下探针是否需要 `--insecure`，以及把 `127.0.0.1` 补进可信主机。

安装器在服务启动后读取**本次启动**的 DSH 登录凭据，并做三道真实认证校验：

1. 未认证的公开基础地址必须返回 **401**（不是 200，也不是被代理放行）。
2. 带凭据的登录 URL 必须返回 **303** 跳转。
3. `Set-Cookie` 必须同时含 `Secure`、`HttpOnly`、`SameSite=Strict`（原生 TLS 模式下由 DSH 依据 https 的 public-url 自行下发）。

任一项不符合就退出，不会声称安装成功。随后还会用带登录 Cookie 的请求对**真实外部入口**（`${DSH_PUBLIC_URL}/api/remote.mux`）做一次真正的 upgrade 握手，必须拿到 **101**。这条路径和浏览器一致，同时覆盖了 Serve；自签证书由脚本用 `--insecure` 只跳过本机校验。可用 `DSH_VERIFY_WS=no` 跳过 WS 检查，但不建议。

> 说明：Cookie 是绑定到签发它的主机名的。因此在 `serve` 模式下检查必须走公开入口，用 loopback 直连且不改 `Host` 会被 DSH 判成未认证；`local-only` 模式没有公开入口可达，探针改为回环 + `127.0.0.1` 可信主机（见「可选模式」）。

完整登录链接不会写入本工具报告或 Git。操作者需要在自己的终端单独运行：

```sh
sudo node --experimental-strip-types \
  tools/login-url.ts --unit dsh-web.service \
  --public-url https://my-machine.example.ts.net/
```

完整链接只应粘贴到预期浏览器或手机浏览器，不要发送到聊天、日志或 issue。手机浏览器仍必须先接入 Tailscale。

入口认证和 API 模型认证是两件事：前者只证明 DSH 登录入口可达，后者需要在 GUI 中保存 provider/model/API 配置并完成一次真实消息请求。

## TLS 与证书生命周期

默认模式有两条互不相干的证书链路：

- **Tailscale Serve 的 HTTPS 证书**由 Tailscale 自己签发和续期，浏览器看到的是这张。它的续期不影响 DSH。
- **DSH 本机的自签证书**（`/etc/dsh/tls/dsh.crt`）只是 Serve → 3080 这段回环链路的凭据，有效期 **3650 天（10 年）**，DSH 不申请、不续期、也不自动重读。

也就是说自签证书默认能用十年；**到期前必须重新生成并重启服务**，否则 Serve 的 `https+insecure` 后端会握手失败。重签：

```sh
sudo rm -f /etc/dsh/tls/dsh.crt /etc/dsh/tls/dsh.key   # 或 DSH_TLS_DAYS 调短后强制重建
sudo ./install.sh                                      # 复用现有安装，只重签并重启
# 只换证书、不动其他配置时：
sudo systemctl reload dsh-web.service
```

`systemctl reload dsh-web.service` 等价于只重启 `dsh-web.service`，不会重启 Tailscale 或其他服务。若改用外部 ACME 证书，请以可靠原子方式替换文件（同目录临时文件、权限校验、原子 rename）后再 reload。

## 诊断与测试

```sh
sudo systemctl status dsh-web.service
sudo ss -ltnp | grep ':3080'
sudo tailscale serve status --json
sudo journalctl -u dsh-web.service -b -n 100 --no-pager
npm test
```

`tests/test.sh` 不接触宿主 systemd 或 Tailscale 状态：隔离 mock 覆盖未登录、HTTPS 未启用、Serve/Funnel 冲突、重复运行、成功和应用失败，以及 401/303 判定；Node 内置测试验证 WebSocket 升级校验。`tests/native-tls.test.sh` 离线覆盖证书生成、SAN、10 年有效期、最小权限、复用与重签、ECDSA 选项、Serve 的 `https+insecure` 参数、默认模式为原生 TLS、代理模式已被移除，以及从旧代理拓扑升级时只接管属于自己的 Serve handler。`tests/layout-local-only.test.sh` 离线覆盖安装布局（程序在 `$DSH_APP_ROOT/app` 且 root 所有、`WorkingDirectory` 指向 `$DSH_HOME/workspace`、程序目录不在 `ReadWritePaths` 里、`MemoryMax=768M` 不回归）和 local-only 自检（探针地址取回环、只有 loopback 探针才放宽证书校验、`127.0.0.1` 只补一次进可信主机，以及用 mock curl 端到端跑通 401/303/Cookie 且确认探针不会跑到 public URL）。`tests/verify-ws.test.cjs` 起一个真实的自签 HTTPS 服务，验证 `tools/verify-ws.mjs` 对带 Cookie 的升级握手给出 101、对无 Cookie 的握手上报失败、不跳过校验时会失败，且任何输出都不含 Cookie 值。测试不会执行 `install.sh`，不会改动宿主 systemd、Tailscale 或 `/etc/dsh`。

2026-11-06 已在 Ubuntu 24.04 / Node 24.22.1 上完成实装验证：未认证入口 401、带令牌登录 303、Cookie 含 `Secure`/`HttpOnly`/`SameSite=Strict`，对 `https://127.0.0.1:3080/api/remote.mux` 带 Cookie 握手得到 101 升级。

### 证书与链路诊断

```sh
# 自签证书剩余有效期（默认模式）
sudo openssl x509 -in /etc/dsh/tls/dsh.crt -noout -enddate
# 证书 SAN 是否覆盖当前 MagicDNS 名称
sudo openssl x509 -in /etc/dsh/tls/dsh.crt -noout -ext subjectAltName
# 权限是否最小化：目录 0750、证书 0644、私钥 0640 root:dsh
sudo ls -ld /etc/dsh/tls /etc/dsh/tls/dsh.crt /etc/dsh/tls/dsh.key
# Serve 后端是不是原生 TLS
sudo tailscale serve status --json
# :3081 不应有监听；有监听说明旧代理单元还在
sudo ss -ltnp | grep -E ':3080|:3081'
```

`openssl x509 -enddate` 的输出（`notAfter=...`）就是证书到期时间，写进工单时只需这一行，不要附带私钥。

## 版本与来源

- DSH：`@deepseek-ai/dsh@0.2.2-rc.1`，npm integrity 在 `install.sh` 中固定校验；依赖以 root 属主安装在 `/opt/dsh/app`（服务用户只读），不创建系统级 npm 命令链接。该 RC 仍是预览版；2026-11-06 在 Ubuntu 24.04 安装时 npm 报告 209 条依赖漏洞（201 高危、8 中危），不建议用于生产或敏感数据。
- DSH 官方仓库：[deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)。
- Tailscale Serve：[官方 CLI 文档](https://tailscale.com/kb/1242/tailscale-serve)。
- Tailscale HTTPS：[官方说明](https://tailscale.com/kb/1153/enabling-https)。

不要提交真实域名、IP、token、API key、私钥或主机配置。
