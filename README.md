# DSH VPS Deploy

把 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 装到 Linux VPS，并且**只通过 Tailscale 私有网络**访问的部署工具。

- 固定版本 `@deepseek-ai/dsh@0.2.2-rc.1`，本仓库不含 DSH 本体，也不含任何域名、IP、token 或私钥。
- 安装器每一步都在**验证**而不是声称：401 → 303 → Cookie 三属性 → 真实 WebSocket 101，任一不符就退出。
- 不启用 Funnel、不开放公网端口、不修改防火墙、不覆盖别人的 Serve handler。

## 快速开始

```sh
# 1. 预检（不改主机，非 root 也能跑）
sudo DSH_DRY_RUN=yes ./install.sh

# 2. 安装
sudo ./install.sh

# 3. 取登录链接，粘到已连 Tailscale 的浏览器
sudo node --experimental-strip-types tools/login-url.ts \
  --unit dsh-web.service --public-url https://my-machine.example.ts.net/
```

装完还差一步：在 Web GUI 里配置模型/API，发一条消息确认能收到回复。

## 拓扑

```
浏览器 ──HTTPS──▶ Tailscale Serve ──https+insecure──▶ DSH ──▶ 模型 API
         (TS 证书，自动续期)      (127.0.0.1:3080,        (loopback only)
                                    自签证书，仅隧道内)
```

**没有本机代理。** TLS 由 DSH 自己终止，所以 `DSH_PUBLIC_URL` 是 https 时 DSH 会给 Cookie 加上 `Secure`，不需要任何中间层去补。

只有两层证书，别搞混：

| 层 | 谁签发 | 谁续期 | 谁验证 |
| --- | --- | --- | --- |
| 外层（浏览器 → Serve） | Tailscale（Let's Encrypt） | tailscaled 自动 | 浏览器 |
| 内层（Serve → DSH） | `openssl` 自签，默认 10 年 | 无人，到期需重签 | 无人（`https+insecure`） |

内层证书只用来让 DSH 进入 TLS 模式并下发 `Secure` Cookie，内容本身不被校验，所以 10 年自签就够了。

## 前置条件

- Linux + systemd + root，Node.js `>=24.9.0`，npm，openssl。脚本用 PATH 里的 `node`，不写死路径。
- 已安装并登录 Tailscale；tailnet 管理员已为 tailnet 启用 HTTPS/MagicDNS。
- 手机也要装 Tailscale 并加入同一 tailnet——能打开网页不代表手机已接入。
- CLI 缺失时，只有已配置官方 apt 源的 Debian/Ubuntu 才接受 `DSH_TAILSCALE_INSTALL=yes`；脚本不会执行第三方 `curl | sh`。

## 模式

```sh
sudo ./install.sh                                    # serve（默认）
sudo DSH_TAILSCALE_MODE=local-only ./install.sh      # 只绑回环，走 SSH 隧道
```

`serve` 会先只读检查 Tailscale（CLI 存在、`BackendState=Running`、有 MagicDNS 名称、Serve/HTTPS 可用、没有别人的 handler、没有 Funnel），通过后才装 DSH、生成证书、启动服务，最后执行：

```sh
tailscale serve --bg --https=443 https+insecure://127.0.0.1:3080
```

`DSH_PUBLIC_URL` 和 `DSH_TRUSTED_HOST` 未指定时从当前机器的 MagicDNS 名称自动探测，该名称也用作证书 SAN。

`local-only` 下 DSH 只绑 `127.0.0.1`，因此自检探针改用回环地址（`DSH_PUBLIC_URL` 可填任意值，写进 env 的仍是真实值）；安装器同时把 `127.0.0.1` 补进可信主机，避免健康服务被自己的探针判成 421。

### 报错时怎么办

| 报错 | 处理 |
| --- | --- |
| 缺 Tailscale | 从官方包源安装，或确认平台后再用 `DSH_TAILSCALE_INSTALL=yes` |
| 未登录 | `sudo tailscale up`，完成授权后跑错误信息里的 continue 命令 |
| HTTPS/Serve 不可用 | 在 Tailscale 管理后台为 tailnet 启用 HTTPS |
| handler 冲突 | `sudo tailscale serve status --json` 自查；本工具不会替你删 |

非交互执行同样返回非零退出码，continue 命令会打到 stderr。别把 token 粘进 shell 历史或工单。

## 安装布局

程序、数据、工作区三者分开：

| 路径 | 属主 / 权限 | 用途 |
| --- | --- | --- |
| `/opt/dsh/app` | `root:root` `0755` | DSH 程序（npm 装在这里，服务用户只读） |
| `/var/lib/dsh` | `dsh:dsh` `0750` | 数据目录，凭据与会话在 `.dsh/` |
| `/var/lib/dsh/workspace` | `dsh:dsh` `0750` | agent 的默认工作区（systemd `WorkingDirectory`） |
| `/etc/dsh` | `root:dsh` `0750` | env 配置（`0640`）与自签证书 |

由此得到：服务用户**改不了自己的程序**（`ProtectSystem=strict` + `ReadWritePaths=/var/lib/dsh`），agent 在工作区里看不到程序目录；升级时先装到 `.app.stage.<pid>`，原子换入后才删旧树。

**这条边界的真实范围**：它挡的是「agent 改写自己的程序」，不是「agent 拿不到 DSH 的秘密」。agent 与服务同用户，所以能读到 `$DSH_HOME/.dsh` 里的凭据、`/etc/dsh/tls/dsh.key` 和 `/etc/dsh/dsh-web.env`。要真正隔离得拆用户加 namespace，本工具没做，也不暗示做了。

## 安装后验证什么

安装器读**本次启动**的登录凭据，做四道真实检查：

1. 未认证基础地址返回 **401**
2. 带凭据的登录 URL 返回 **303**
3. `Set-Cookie` 同时含 `Secure`、`HttpOnly`、`SameSite=Strict`
4. 带 Cookie 请求 `${DSH_PUBLIC_URL}/api/remote.mux` 拿到 **101**

第 4 条走的就是浏览器路径，顺带覆盖了 Serve。证书校验只对回环探针用 `--insecure`。跳过 WS 检查可设 `DSH_VERIFY_WS=no`，不建议。

> Cookie 绑定签发它的主机名，所以 `serve` 模式必须走公开入口；`local-only` 没有公开入口可达，才改用回环 + 可信主机。

## 配置项

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `DSH_USER` | `dsh` | 服务用户 |
| `DSH_HOME` | `/var/lib/dsh` | 数据目录 |
| `DSH_APP_ROOT` | `/opt/dsh` | 程序根，实际装在 `$DSH_APP_ROOT/app` |
| `DSH_PORT` | `3080` | DSH 监听端口 |
| `DSH_TLS_CERT` / `DSH_TLS_KEY` | 空 | 自带证书，跳过自签 |
| `DSH_TLS_DIR` | `/etc/dsh/tls` | 自签证书位置 |
| `DSH_TLS_KEY_TYPE` | `rsa2048` | `rsa2048` 或 `ecdsa` |
| `DSH_TLS_DAYS` | `3650` | 自签有效期 |
| `DSH_MEMORY_HIGH` | `512M` | 内存软限，超过会被限流 |
| `DSH_MEMORY_MAX` | `768M` | 内存硬限，超过 OOM 杀**整个 Web UI** |
| `DSH_CPU_QUOTA` | `75%` | CPU 配额 |
| `DSH_TASKS_MAX` | `128` | 进程/线程上限 |
| `DSH_ENABLE` | `yes` | 装完是否启动服务 |
| `DSH_VERIFY_WS` | `yes` | 是否做 WebSocket 断言 |
| `DSH_DRY_RUN` | `no` | 只校验输入和资源，不改主机 |

两个内存值**必须带单位后缀**。systemd 把裸数字当字节，`DSH_MEMORY_MAX=1024` 会得到 1 KiB 上限、服务根本起不来，所以安装器直接拒绝这种写法。

实测（2 GiB VPS、单 agent、普通对话）峰值约 400 MiB，距默认 `MemoryHigh` 只剩约 100 MiB 余量。跑大仓库构建或批量改动时建议 `DSH_MEMORY_HIGH=1G DSH_MEMORY_MAX=1536M`，自己量：

```sh
systemctl show dsh-web.service -p MemoryPeak,MemoryHigh,MemoryMax
```

## 诊断

```sh
sudo systemctl status dsh-web.service
sudo journalctl -u dsh-web.service -b -n 100 --no-pager
sudo tailscale serve status --json
sudo ss -ltnp | grep ':3080'          # :3081 不该有监听

# 证书
sudo openssl x509 -in /etc/dsh/tls/dsh.crt -noout -enddate
sudo openssl x509 -in /etc/dsh/tls/dsh.crt -noout -ext subjectAltName
sudo ls -ld /etc/dsh/tls /etc/dsh/tls/dsh.crt /etc/dsh/tls/dsh.key
```

`notAfter=...` 就是到期时间，贴工单只需这一行，别附私钥。

## 测试

```sh
npm test        # 非 root 也能跑；CI 用同一条命令
```

离线覆盖：Serve/Funnel 冲突检测（用真实 `Handlers`/`Proxy` JSON 形状）、无认证与 401/303、Cookie 三属性、本地代理的 Host 与 WS 转发、证书生成与 SAN、安装布局与权限、local-only 探针、env 文件转义，以及一个真实的自签 HTTPS 服务验证 WS 握手。

**它不能证明的**：真实 systemd 加载 unit、活的 Tailscale、对运行中 DSH 的端到端握手。测试全绿只说明逻辑成立，不代表某台机器部署健康。

2026-11-06 在 Ubuntu 24.04 / Node 24.22.1 上完成过实装验证：401、303、Cookie 三属性、`/api/remote.mux` 握手 101 全部通过。

## 已知限制

- **不提供回滚**：升级时新树原子换入、旧树随后删除，失败后回不到上一版本。升级前先备份 `$DSH_HOME`（`.dsh` 里有凭据、会话和工作区）。
- 自签证书到期（默认 10 年）需要重新生成并重启服务，没有自动续期；外层的 Tailscale 证书是自动的。
- DSH 是 `0.2.2-rc.1` 预览版。2026-11-06 在 Ubuntu 24.04 安装时 npm 报告 209 条依赖漏洞（201 高危、8 中危），不要用于生产或敏感数据。

## 来源

- DSH 官方仓库：[deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)
- Tailscale Serve：[tailscale.com/kb/1242](https://tailscale.com/kb/1242/tailscale-serve)
- Tailscale HTTPS：[tailscale.com/kb/1153](https://tailscale.com/kb/1153/enabling-https)
