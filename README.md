# DSH VPS Deploy

这是一个可审阅、可重复的通用 Linux VPS 部署工具，固定安装 `@deepseek-ai/dsh@0.2.2-rc.1`，不是 DSH 本体。默认流程是 **原生 TLS + Tailscale Serve 私有 HTTPS**：安装器用 `openssl` 生成 10 年期自签证书，DSH 自己用 `--tls-cert`/`--tls-key` 在 `127.0.0.1:3080` 上跑 HTTPS，Serve 通过 `https+insecure://127.0.0.1:3080` 直连它，**中间没有本机代理**。因为后端本身就是 HTTPS，`DSH_PUBLIC_URL` 为 https 时 DSH 会自己给 Cookie 加 `Secure`，不需要代理补。入口仍受 tailnet ACL/设备接入控制。本流程不会启用 Funnel、开放公网端口或修改防火墙。

旧的 `dsh-web-proxy.service`（127.0.0.1:3081 校验 Host、补 Secure Cookie）保留为**可选回退**，默认不安装、不启用。

工具不包含任何域名、IP、账号、token、私钥或 API key。

## 新人前置条件

- Linux、systemd、root，Node.js `>=24.9.0` 和 npm。脚本使用 PATH 中的 `node`，不会写死某台机器的 Node 路径。
- 默认模式需要已安装并运行 Tailscale。若 CLI 不存在，脚本只在已配置官方 apt 源、且可核验为 Debian/Ubuntu 系统时接受 `DSH_TAILSCALE_INSTALL=yes`；它不会执行第三方 `curl | sh`。没有明确授权时，安装器退出并给出继续命令。
- Tailscale 必须已登录，tailnet 管理员必须启用 HTTPS/MagicDNS。手机访问前，手机也必须安装 Tailscale 并加入同一 tailnet；浏览器能看到页面不代表手机已接入。
- DSH 的模型/API 仍需在 Web GUI 的设置中配置。至少选择 DeepSeek provider、填写真实 API 模型配置，并发送一条最小消息确认 assistant 回复；Serve 不会替你配置 API。

这是私有 tailnet 入口，不是公网自动开放方案。默认模式下没有中间代理：TLS 由 DSH 自己终止，Cookie 的 `Secure` 由 DSH 依据 https 的 `DSH_PUBLIC_URL` 自行下发。只有回退到 proxy 模式时代理才会介入，且只绑定 loopback。Funnel 与 Serve 是不同功能，本文和脚本都不会替你打开 Funnel。

## 默认安装

先做不改主机的预检：

```sh
sudo DSH_DRY_RUN=yes ./install.sh
```

默认安装会先只读检查 Tailscale：CLI 存在、`BackendState=Running`、有本机 MagicDNS 名称、Serve/HTTPS 可用、没有已有不同 handler，也没有 Funnel。之后才在独立目录安装 DSH，生成自签证书，只启动 `dsh-web.service`（不再启用 `dsh-web-proxy.service`），并执行：

```sh
tailscale serve --bg --https=443 https+insecure://127.0.0.1:3080
```

`DSH_PUBLIC_URL` 和 `DSH_TRUSTED_HOST` 未显式提供时，会从 Tailscale 当前机器的 DNS 名称自动探测，该名称同时用作证书 SAN。可显式固定：

```sh
sudo DSH_PUBLIC_URL=https://my-machine.example.ts.net/ \
  DSH_TRUSTED_HOST=my-machine.example.ts.net ./install.sh
```

Serve 已有其他服务时安装器会退出，不会 reset、替换或重启其他服务。重复运行时，如果现有 handler 已经指向本模式的后端（默认 `https+insecure://127.0.0.1:3080`，回退模式为 `http://127.0.0.1:3081`），它会视为已配置；应用失败也不会冒充成功。从旧版本升级时，安装器会停用并移除遗留的 `dsh-web-proxy.service`。

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

`DSH_TAILSCALE_MODE=serve-proxy` 是旧的回退拓扑：DSH 明文跑 3080，本机代理监听 3081 并补 Secure Cookie，Serve 指向 3081。等价简写是 `DSH_TLS_MODE=proxy`。只有在原生 TLS 出问题时才需要它：

```sh
sudo DSH_TLS_MODE=proxy ./install.sh
# 等价于
sudo DSH_TAILSCALE_MODE=serve-proxy ./install.sh
```

切回默认原生 TLS 直接重跑 `sudo ./install.sh`，代理服务会被停用并移除。

`DSH_TAILSCALE_MODE=external-proxy` 不使用 Tailscale Serve，但安装本机代理；你的 HTTPS 反代应转发到 `http://127.0.0.1:3081`，保留 Host/Origin、WebSocket Upgrade 和挂载路径。注意此模式下 **DSH 不自行下发 Secure**，安装器会实际认证并检查 `Set-Cookie` 同时含 `Secure`、`HttpOnly` 和 `SameSite=Strict`，不满足就失败。

也可以自己提供证书：给出 `DSH_TLS_CERT` 和 `DSH_TLS_KEY` 即跳过自签生成，仍走原生 TLS（Serve 依旧 `https+insecure://`），且 `DSH_PUBLIC_URL` 必须是 HTTPS。自签相关的可调项：`DSH_TLS_MODE`（`native` 默认 / `proxy`）、`DSH_TLS_DIR`（默认 `/etc/dsh/tls`）、`DSH_TLS_KEY_TYPE`（`rsa2048` 默认 / `ecdsa`）、`DSH_TLS_DAYS`（默认 `3650`）。

通用变量：`DSH_USER`（默认 `dsh`）、`DSH_HOME`（默认 `/var/lib/dsh`）、`DSH_PORT`（默认 `3080`）、`DSH_PROXY_PORT`（默认 `3081`）、`DSH_ENABLE`（默认 `yes`）。DSH 的 systemd 内存上限为 768M，本机代理为 128M，均由独立用户运行。

## 认证与验证

- `tools/gen-selfsigned-cert.sh`：生成/复用自签证书。目录 `0750`、证书 `0644`、私钥 `0640` 且属主 `root`、组为 DSH 服务用户，SAN 含 MagicDNS 主机名、`localhost` 和 `127.0.0.1`；仍在有效期内且 SAN 匹配时不会重签。
- `tools/rotate-native-tls.sh`：校验证书、私钥及公钥匹配后，原子替换同目录文件并只 reload `dsh-web.service`。
- `tools/verify-ws.mjs`：对目标做一次真实 WebSocket upgrade 握手，只打印状态码，从不打印 Cookie 值。

安装器在服务启动后读取**本次启动**的 DSH 登录凭据，并做三道真实认证校验：

1. 未认证的公开基础地址必须返回 **401**（不是 200，也不是被代理放行）。
2. 带凭据的登录 URL 必须返回 **303** 跳转。
3. `Set-Cookie` 必须同时含 `Secure`、`HttpOnly`、`SameSite=Strict`（原生 TLS 模式下由 DSH 依据 https 的 public-url 自行下发）。

任一项不符合就退出，不会声称安装成功。随后还会用带登录 Cookie 的请求对**真实外部入口**（`${DSH_PUBLIC_URL}/api/remote.mux`）做一次真正的 upgrade 握手，必须拿到 **101**。这条路径和浏览器一致，同时覆盖了 Serve；自签证书由脚本用 `--insecure` 只跳过本机校验。可用 `DSH_VERIFY_WS=no` 跳过 WS 检查，但不建议。

> 说明：Cookie 是绑定到签发它的主机名的（原生 TLS 下是 `127.0.0.1`，代理回退下是公开的 MagicDNS 名），所以这条检查必须走公开入口；用 loopback 直连且改写 `Host` 会被 DSH 判成未认证。

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
sudo systemctl status dsh-web.service dsh-web-proxy.service
sudo ss -ltnp | grep -E ':3080|:3081'
sudo tailscale serve status --json
sudo journalctl -u dsh-web.service -b -n 100 --no-pager
npm test
```

`tests/test.sh` 不接触宿主 systemd 或 Tailscale 状态：隔离 mock 覆盖未登录、HTTPS 未启用、Serve/Funnel 冲突、重复运行、成功和应用失败，以及 401/303 判定；Node 内置测试验证 Cookie Secure、Host 限制和 WebSocket 双向转发。`tests/native-tls.test.sh` 离线覆盖证书生成、SAN、10 年有效期、最小权限、复用与重签、ECDSA 选项、Serve 的 `https+insecure` 参数、默认模式为原生 TLS、proxy 回退仍可用、代理服务默认不启用，以及从旧代理拓扑迁移时只接管属于自己的 Serve handler。`tests/verify-ws.test.cjs` 起一个真实的自签 HTTPS 服务，验证 `tools/verify-ws.mjs` 对带 Cookie 的升级握手给出 101、对无 Cookie 的握手上报失败、不跳过校验时会失败，且任何输出都不含 Cookie 值。测试不会执行 `install.sh`，不会改动宿主 systemd、Tailscale 或 `/etc/dsh`。

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
# 端口上到底有没有代理
sudo ss -ltnp | grep -E ':3080|:3081'
```

`openssl x509 -enddate` 的输出（`notAfter=...`）就是证书到期时间，写进工单时只需这一行，不要附带私钥。

## 版本与来源

- DSH：`@deepseek-ai/dsh@0.2.2-rc.1`，npm integrity 在 `install.sh` 中固定校验；依赖安装在独立的服务目录，不创建系统级 npm 命令链接。该 RC 仍是预览版；2026-11-06 在 Ubuntu 24.04 安装时 npm 报告 209 条依赖漏洞（201 高危、8 中危），不建议用于生产或敏感数据。
- DSH 官方仓库：[deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)。
- Tailscale Serve：[官方 CLI 文档](https://tailscale.com/kb/1242/tailscale-serve)。
- Tailscale HTTPS：[官方说明](https://tailscale.com/kb/1153/enabling-https)。

不要提交真实域名、IP、token、API key、私钥或主机配置。
