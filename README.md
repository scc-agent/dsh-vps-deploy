# DSH VPS Deploy

把 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 装到 Linux VPS，并且**只通过 Tailscale 私有网络**访问的部署工具。

- 固定 `@deepseek-ai/dsh@0.2.2-rc.1`，本仓库不含 DSH 本体，也不含任何域名、IP、token 或私钥。
- 安装器每一步都在**验证**而不是声称：401 → 303 → Cookie 三属性 → 真实 WebSocket 101，任一不符就退出。
- 不启用 Funnel、不开放公网端口、不修改防火墙、不覆盖别人的 Serve handler。

## 快速开始

```sh
sudo DSH_DRY_RUN=yes ./install.sh   # 预检，不改主机，非 root 也能跑
sudo ./install.sh                   # 安装
sudo node --experimental-strip-types tools/login-url.ts \
  --unit dsh-web.service --public-url https://my-machine.example.ts.net/
```

最后一条会打印带令牌的登录链接，粘到已连 Tailscale 的浏览器。装完还差一步：在 Web GUI 里配置模型/API，发一条消息确认能收到回复。

## 拓扑

```
浏览器 ──HTTPS──▶ Tailscale Serve ──https+insecure──▶ DSH ──▶ 模型 API
         (TS 证书，自动续期)      (127.0.0.1:3080,        (仅 loopback)
                                    自签证书，仅隧道内)
```

**没有本机代理。** TLS 由 DSH 自己终止，所以 `DSH_PUBLIC_URL` 是 https 时它会给 Cookie 加上 `Secure`，不需要中间层去补。

两层证书：外层由 Tailscale 自动签发和续期，浏览器验证；内层是 `openssl` 自签（默认 10 年），只用来让 DSH 进入 TLS 模式，Serve 用 `https+insecure` 不校验它，所以到期重签即可。

## 前置条件

- Linux + systemd + root，Node.js `>=24.9.0`，npm，openssl。脚本用 PATH 里的 `node`，不写死路径。
- 已安装并登录 Tailscale，tailnet 管理员已启用 HTTPS/MagicDNS；手机也要装 Tailscale 并加入同一 tailnet。
- CLI 缺失时，只有已配置官方 apt 源的 Debian/Ubuntu 才接受 `DSH_TAILSCALE_INSTALL=yes`；脚本不会执行第三方 `curl | sh`。

## 模式

```sh
sudo ./install.sh                                 # serve（默认）
sudo DSH_TAILSCALE_MODE=local-only ./install.sh   # 只绑回环，走 SSH 隧道
```

`serve` 会先只读检查 Tailscale（CLI、`BackendState=Running`、MagicDNS 名称、Serve/HTTPS 可用、没有别人的 handler、没有 Funnel），通过后才装 DSH、生成证书、启动服务，最后执行 `tailscale serve --bg --https=443 https+insecure://127.0.0.1:3080`。

`DSH_PUBLIC_URL` 和 `DSH_TRUSTED_HOST` 未指定时从 MagicDNS 名称自动探测，该名称也用作证书 SAN。

`local-only` 下 DSH 只绑 `127.0.0.1`，自检探针因此改用回环地址，并把 `127.0.0.1` 补进可信主机，避免健康服务被自己的探针判成 421。

| 报错 | 处理 |
| --- | --- |
| 缺 Tailscale | 从官方包源安装，或确认平台后再用 `DSH_TAILSCALE_INSTALL=yes` |
| 未登录 | `sudo tailscale up`，完成授权后跑错误信息里的 continue 命令 |
| HTTPS/Serve 不可用 | 在 Tailscale 管理后台为 tailnet 启用 HTTPS |
| handler 冲突 | `sudo tailscale serve status --json` 自查；本工具不会替你删 |

## 安装布局

| 路径 | 属主 / 权限 | 用途 |
| --- | --- | --- |
| `/opt/dsh/app` | `root:root` `0755` | DSH 程序，服务用户只读 |
| `/var/lib/dsh` | `dsh:dsh` `0750` | 数据目录，凭据与会话在 `.dsh/` |
| `/var/lib/dsh/workspace` | `dsh:dsh` `0750` | agent 的默认工作区 |
| `/etc/dsh` | `root:dsh` `0750` | env 配置与自签证书 |

服务用户**改不了自己的程序**（`ProtectSystem=strict` + `ReadWritePaths=/var/lib/dsh`），agent 在工作区里看不到程序目录；升级时先装到 `.app.stage.<pid>`，原子换入后才删旧树。

**DSH_HOME 写死了**：服务在 `/etc/dsh/dsh-web.env` 里把 DSH 程序认的 `DSH_HOME`（数据目录）固定为 `/var/lib/dsh/.dsh`，profile 在 `/var/lib/dsh/.dsh/profiles/web`。注意它和安装器的 `DSH_HOME` 变量不是一个意思——安装器的 `DSH_HOME` 是服务用户的家目录（`/var/lib/dsh`），而 DSH 程序认的 `DSH_HOME` 是数据目录（`/var/lib/dsh/.dsh`）。手动跑 DSH 命令时必须用数据目录（`DSH_HOME=/var/lib/dsh/.dsh`），用家目录会指到一个空的 profile，插件装了也不加载。

**边界范围**：它挡的是「agent 改写自己的程序」，不是「agent 拿不到 DSH 的秘密」。agent 与服务同用户，所以能读到 `.dsh` 里的凭据、`/etc/dsh/tls/dsh.key` 和 `/etc/dsh/dsh-web.env`。要真正隔离得拆用户加 namespace，本工具没做。

## 配置项

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `DSH_USER` / `DSH_HOME` | `dsh` / `/var/lib/dsh` | 服务用户与数据目录 |
| `DSH_APP_ROOT` | `/opt/dsh` | 程序根，实际装在 `$DSH_APP_ROOT/app` |
| `DSH_PORT` | `3080` | DSH 监听端口 |
| `DSH_TLS_CERT` / `DSH_TLS_KEY` | 空 | 自带证书，跳过自签 |
| `DSH_MEMORY_HIGH` / `DSH_MEMORY_MAX` | `512M` / `768M` | 内存软限（限流）/ 硬限（OOM 杀整个 Web UI） |
| `DSH_CPU_QUOTA` / `DSH_TASKS_MAX` | `75%` / `128` | CPU 配额与进程上限 |
| `DSH_ENABLE` / `DSH_VERIFY_WS` | `yes` | 是否启动服务 / 是否做 WS 断言 |
| `DSH_DRY_RUN` | `no` | 只校验输入和资源，不改主机 |

自签相关：`DSH_TLS_DIR`（`/etc/dsh/tls`）、`DSH_TLS_KEY_TYPE`（`rsa2048` 或 `ecdsa`）、`DSH_TLS_DAYS`（`3650`）。

两个内存值**必须带单位后缀**。systemd 把裸数字当字节，`DSH_MEMORY_MAX=1024` 会得到 1 KiB 上限、服务根本起不来，所以安装器直接拒绝这种写法。

实测（2 GiB VPS、单 agent、普通对话）峰值约 400 MiB，距默认 `MemoryHigh` 只剩约 100 MiB。跑大构建建议 `DSH_MEMORY_HIGH=1G DSH_MEMORY_MAX=1536M`，自己量用 `systemctl show dsh-web.service -p MemoryPeak,MemoryHigh,MemoryMax`。

## 验证

安装器读**本次启动**的登录凭据做四道真实检查：未认证地址 401、带凭据登录 303、`Set-Cookie` 含 `Secure`/`HttpOnly`/`SameSite=Strict`、带 Cookie 请求 `/api/remote.mux` 拿到 101。最后一条走的就是浏览器路径，顺带覆盖了 Serve。

```sh
npm test    # 非 root 也能跑，CI 用同一条命令
```

离线覆盖 Serve/Funnel 冲突（真实 `Handlers`/`Proxy` JSON 形状）、401/303、Cookie 三属性、证书与 SAN、安装布局与权限、local-only 探针，以及一个真实的自签 HTTPS 服务验证 WS 握手。env 文件只用 grep 断言过没退回 `%q`，没有行为测试。

**它不能证明的**：真实 systemd 加载 unit、活的 Tailscale、对运行中 DSH 的端到端握手。测试全绿只说明逻辑成立。2026-11-06 在 Ubuntu 24.04 / Node 24.22.1 上做过实装验证，四项检查全部通过。

## 诊断

```sh
sudo systemctl status dsh-web.service
sudo journalctl -u dsh-web.service -b -n 100 --no-pager
sudo tailscale serve status --json
sudo ss -ltnp | grep ':3080'    # :3081 不该有监听

# 证书到期时间（贴工单只需这一行，别附私钥）
sudo openssl x509 -in /etc/dsh/tls/dsh.crt -noout -enddate
```

## 已知限制

- **不提供回滚**：升级时新树原子换入、旧树随后删除，失败后回不到上一版本。升级前先备份 `$DSH_HOME`。
- 自签证书到期（默认 10 年）需重新生成并重启服务，没有自动续期；外层 Tailscale 证书是自动的。
- DSH 是 `0.2.2-rc.1` 预览版。2026-11-06 安装时 npm 报告 209 条依赖漏洞（201 高危、8 中危），不要用于生产或敏感数据。安装树不带 lockfile，直接在里面跑 `npm audit` 会报 `ENOLOCK`，要审就这样：

  ```sh
  mkdir -p /tmp/audit
  npm install --package-lock-only --prefix /tmp/audit @deepseek-ai/dsh@0.2.2-rc.1
  cd /tmp/audit && npm audit --omit=dev
  ```

## 来源

[deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) · [Tailscale Serve](https://tailscale.com/kb/1242/tailscale-serve) · [Tailscale HTTPS](https://tailscale.com/kb/1153/enabling-https)
