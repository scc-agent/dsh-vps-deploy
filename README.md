# DSH VPS Deploy

这是一个可审阅、可重复的 Linux VPS 部署工具，固定安装 `@deepseek-ai/dsh@0.2.2-rc.1`。默认流程是 **Tailscale Serve 私有 HTTPS**：DSH 只监听 `127.0.0.1`，Serve 反代到该端口，入口仍受 tailnet ACL/设备接入控制。本流程不会启用 Funnel、开放公网端口、修改防火墙，也不会覆盖其他 Serve handler。

工具不包含任何域名、IP、账号、token、私钥或 API key。

## 新人前置条件

- Linux、systemd、root，Node.js `>=24.9.0` 和 npm。脚本使用 PATH 中的 `node`，不会写死某台机器的 Node 路径。
- 默认模式需要已安装并运行 Tailscale。若 CLI 不存在，脚本只在已配置官方 apt 源、且可核验为 Debian/Ubuntu 系统时接受 `DSH_TAILSCALE_INSTALL=yes`；它不会执行第三方 `curl | sh`。没有明确授权时，安装器退出并给出继续命令。
- Tailscale 必须已登录，tailnet 管理员必须启用 HTTPS/MagicDNS。手机访问前，手机也必须安装 Tailscale 并加入同一 tailnet；浏览器能看到页面不代表手机已接入。
- DSH 的模型/API 仍需在 Web GUI 的设置中配置。至少选择 DeepSeek provider、填写真实 API 模型配置，并发送一条最小消息确认 assistant 回复；Serve 不会替你配置 API。

这是私有 tailnet 入口，不是公网自动开放方案。Funnel 与 Serve 是不同功能，本文和脚本都不会替你打开 Funnel。

## 默认安装

先做不改主机的预检：

```sh
sudo DSH_DRY_RUN=yes ./install.sh
```

默认安装会先只读检查 Tailscale：CLI 存在、`BackendState=Running`、有本机 MagicDNS 名称、Serve/HTTPS 可用、没有已有不同 handler，也没有 Funnel。之后才安装 DSH、启动 `dsh-web.service`，并执行：

```sh
tailscale serve --bg --https=443 http://127.0.0.1:3080
```

`DSH_PUBLIC_URL` 和 `DSH_TRUSTED_HOST` 未显式提供时，会从 Tailscale 当前机器的 DNS 名称自动探测。可显式固定：

```sh
sudo DSH_PUBLIC_URL=https://my-machine.example.ts.net/ \
  DSH_TRUSTED_HOST=my-machine.example.ts.net ./install.sh
```

Serve 已有其他服务时安装器会退出，不会 reset、替换或重启其他服务。重复运行时，如果现有 handler 已经指向本工具的 `127.0.0.1:3080`，它会视为已配置；应用失败也不会冒充成功。

### 缺失、未登录或 HTTPS 未启用

错误信息会明确区分：

- 缺少 Tailscale：先从官方包源安装；仅在确认平台和 apt 源后才可显式使用 `DSH_TAILSCALE_INSTALL=yes`。
- 未登录：执行 `sudo tailscale up`，完成授权后运行错误消息中的 continue 命令。
- HTTPS/Serve 不可用：在 Tailscale 管理界面为 tailnet 启用 HTTPS，再运行 continue 命令。
- 冲突：先用 `sudo tailscale serve status --json` 审阅现有配置；本工具不会替你删除它。

非交互执行也会返回非零状态，继续命令会明确显示在 stderr。无 `sudo` 的环境请自行用等价 root 命令，不要把 token 粘进 shell 历史或工单。

## 可选模式

`DSH_TAILSCALE_MODE=serve` 是默认且推荐的私有 HTTPS 模式。

`DSH_TAILSCALE_MODE=local-only` 保持 loopback，只适合 SSH 隧道或本机访问：

```sh
sudo DSH_TAILSCALE_MODE=local-only ./install.sh
```

`DSH_TAILSCALE_MODE=external-proxy` 保留现有反代方式。外部反代必须使用 HTTPS，保留浏览器的 Host/Origin、WebSocket Upgrade，并正确处理挂载路径和 cookie Path。

`DSH_TAILSCALE_MODE=native-tls` 让 DSH 自己使用同时提供的 `DSH_TLS_CERT`/`DSH_TLS_KEY`。证书必须是匹配的可读 PEM 文件，且 `DSH_PUBLIC_URL` 必须是 HTTPS。该模式不由 Tailscale Serve 管理。

通用变量：`DSH_USER`（默认 `dsh`）、`DSH_HOME`（默认 `/var/lib/dsh`）、`DSH_PORT`（默认 `3080`）、`DSH_ENABLE`（默认 `yes`）。systemd 保留 `MemoryMax=768M`，服务继续由独立用户运行。

## 认证与验证

- `tools/rotate-native-tls.sh`：校验证书、私钥及公钥匹配后，原子替换同目录文件并只 reload `dsh-web.service`。

安装器在服务启动后读取**本次启动**的 DSH 登录凭据，并通过实际入口发起一次认证 URL 请求；失败就退出，不会声称成功。完整登录链接不会写入本工具报告或 Git。操作者需要在自己的终端单独运行：

```sh
sudo -u dsh node --experimental-strip-types \
  tools/login-url.ts --unit dsh-web.service \
  --public-url https://my-machine.example.ts.net/
```

完整链接只应粘贴到预期浏览器或手机浏览器，不要发送到聊天、日志或 issue。手机浏览器仍必须先接入 Tailscale。

入口认证和 API 模型认证是两件事：前者只证明 DSH 登录入口可达，后者需要在 GUI 中保存 provider/model/API 配置并完成一次真实消息请求。

## TLS 与证书生命周期

Tailscale Serve 的 HTTPS 证书由 Tailscale 管理，Serve 的证书续期不等于 DSH 本机证书文件续期；本流程不会把 Serve 误说成 `DSH_TLS_CERT`/`DSH_TLS_KEY` 的文件管理器。

native TLS 的证书文件完全是另一条生命周期。DSH 不申请、续期或自动重新读取它们。续期维护必须由外部 ACME/证书系统以可靠原子方式替换文件（同目录临时文件、权限校验、原子 rename），然后只 reload 本工具服务：

```sh
sudo systemctl reload dsh-web.service
```

本 unit 的 reload 等价于只重启 `dsh-web.service`，不会重启 Tailscale 或其他服务。仅使用 Serve 时，不要生成或复制本机证书副本，也不需要因 Serve 续期重载 DSH。

## 诊断与测试

```sh
sudo systemctl status dsh-web.service
sudo ss -ltnp | grep ':3080'
sudo tailscale serve status --json
sudo journalctl -u dsh-web.service -b -n 100 --no-pager
npm test
```

`tests/test.sh` 不接触宿主 systemd、Tailscale 状态或网络：它使用隔离 mock 覆盖未登录、HTTPS 未启用、Serve 冲突、重复运行、成功和应用失败，并检查 DSH 版本、loopback、MemoryMax 与路径行为。mock 回归不等同于全新机器集成测试。

## 版本与来源

- DSH：`@deepseek-ai/dsh@0.2.2-rc.1`，npm integrity 在 `install.sh` 中固定校验。
- DSH 官方仓库：[deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)。
- Tailscale Serve：[官方 CLI 文档](https://tailscale.com/kb/1242/tailscale-serve)。
- Tailscale HTTPS：[官方说明](https://tailscale.com/kb/1153/enabling-https)。

不要提交真实域名、IP、token、API key、私钥或主机配置。
