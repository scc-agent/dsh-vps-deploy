# 通用 DSH VPS 部署工具（0.2.2-rc.1）

这是一个**通用部署工具仓库**：它安装并运行固定版本的 `@deepseek-ai/dsh` Web 组件，提供 systemd、loopback、反代和诊断辅助。它**不是 DSH 本体**，也不是任何现有的私人服务、私人 VPS 配置或凭据备份；仓库不包含某台机器的域名、IP、账号、密钥或私有配置。

本工具面向可审阅、可重复的 Linux VPS 部署。它默认只让 Web 服务监听 `127.0.0.1`，不启用 Tailscale Funnel、不打开防火墙端口、不停用或覆盖其他服务；安装前会拒绝覆盖没有本项目标记的同名 systemd unit。

> 版本边界：本文和脚本固定 `@deepseek-ai/dsh@0.2.2-rc.1`。官方仓库当前 `package.json` 声明 Node `>=24.9.0`，请不要用旧 Node 猜测安装结果。

## 目录

- `install.sh`：最小、幂等安装器；只在 root 下运行，默认创建 `dsh` 独立用户、安装固定 npm 包并生成 unit。
- `systemd/dsh-web.service.in`：systemd 模板。服务只绑定 `127.0.0.1`，不负责反代、证书签发或防火墙。
- `tools/login-url.ts`：从当前 systemd 主进程对应的本次启动日志读取最新启动凭据，并把它换算为正确的外部 URL。
- `tests/test.sh`：不触碰宿主服务的 shell 静态检查与隔离 mock 测试。

## 新手前置条件

安装器不是无权限的用户态安装脚本。开始前确认：

- 一台受你管理的 Linux VPS，使用 systemd；具备 `root` 或可用 `sudo`，并能创建系统用户、写入 `/etc/dsh`、`/etc/systemd/system` 和 `/usr/local/libexec`。
- Node.js `>=24.9.0`，npm，以及能访问 `https://registry.npmjs.org` 的网络。Node 版本必须由 `node --version` 真实确认；不支持用旧 Node 或只安装 `npx` 猜测。Node 24 的内置 TypeScript type stripping 用于 `tools/login-url.ts`，不需要全局安装 `ts-node`/`tsx`；执行时必须使用 `node --experimental-strip-types`。
- 能运行固定包的 Linux 环境和磁盘空间；安装器执行 `npm view` 校验 tarball integrity，再执行全局 `npm install --global --omit=dev --ignore-scripts`。
- 计划中的端口（默认 `3080`）只允许 loopback/可信反代使用。不要为了让浏览器访问而把它开放到公网。
- 若使用反代，准备一个真实的 HTTPS 域名，并让反代保留外部 `Host`/`Origin`、WebSocket 升级头和正确的 cookie 路径。
- 若使用 DSH 自带 HTTPS，准备完整证书链和不加密 PEM 私钥；两个变量必须同时提供，DSH 不会签发或续期证书。

先审阅 `install.sh`、变量和即将生成的 unit。可先做不改机器的资源预检：

```sh
DSH_DRY_RUN=yes ./install.sh
```

该预检从脚本自身目录读取模板，即使从任意当前工作目录调用也不会执行用户创建、npm 安装、systemd 或文件写入。

## 对外访问边界

**SSH 隧道（私有访问）**：服务继续监听远端 `127.0.0.1:3080`，本地执行端口转发，例如 `ssh -N -L 3080:127.0.0.1:3080 user@host`，然后在本地浏览器打开登录工具输出的 URL。SSH 隧道只给持有 SSH 权限的人访问，不是公网发布；不要把带 token 的启动 URL 发给不预期的人员。

**Tailscale 私有 HTTPS**：可以让已有 Tailscale Serve/HTTPS 作为私有网络入口，反代到 `http://127.0.0.1:3080`，并将实际访问的 hostname 设置为 `DSH_PUBLIC_URL` 和 `DSH_TRUSTED_HOST`。本仓库不调用 `tailscale serve`，不配置 ACL，也不验证你的 tailnet 策略；请按现有 Tailscale 管理边界确认只有 tailnet 用户可达。

**Funnel 是公网边界**：Tailscale Funnel 会把入口暴露给互联网，不能把它描述成 SSH 隧道或私有 HTTPS。若你明确选择 Funnel，必须另行审阅域名、ACL/认证、速率限制和 token 泄露风险；本工具默认不启用、不配置 Funnel。无论入口是什么，DSH 的 `--trusted-host` 只做 Host/Origin 信任，不是公网访问控制。

## 模型配置

启动后在 Web GUI 的“设置 → 模型”中选择 DeepSeek，使用 `DEEPSEEK_API_KEY`。密钥只作为凭据引用或主机环境/凭据服务输入，**不要写进 unit、README、shell 历史、`.env` 提交内容或 git**。仓库示例只使用 `.invalid` 域名。

固定版本的 DeepSeek Messages 配置事实如下：

- 官方 `baseURL` 是 `https://api.deepseek.com/anthropic`；兼容 Messages 的网关也填写其真实根地址。
- 请求会使用 `/v1/messages` 和 `/v1/files`。如果你填的 base URL 已经以严格的 `/v1` 结尾，DSH 会直接复用该路径，不会一律追加成 `/v1/v1/messages`；末尾斜线不改变结果。不要把完整 `/v1/messages` 当作 base URL。
- base URL 必须是 HTTP(S)，不能带凭据、查询串或 fragment。网关是否支持 `deepseek-flash` 等模型由网关决定，DSH 不会替你探测兼容性。
- 真实模型消息前先保存模型配置，再发送一条最小文本消息；看到 assistant 回复才算模型链路验证完成。仅页面能打开或能看到模型下拉框不算 API 验证。

## 安装后验证与诊断

按顺序执行并保留输出中的非敏感诊断：

1. `sudo systemctl status dsh-web.service`：确认 unit active/running。
2. `sudo ss -ltnp | grep ':3080'` 或等价工具：确认只监听 `127.0.0.1:3080`，不要只看进程存在。
3. 用 `login-url.ts` 读取**本次启动** URL，在浏览器完成登录；不要复用旧 journal 行或旧 token。
4. 页面加载后，在设置中确认 provider、模型和凭据引用，发送一条最小真实模型消息并确认 assistant 响应。
5. 失败时先看 `sudo journalctl -u dsh-web.service -b -n 100 --no-pager`，再看浏览器 Network 的 HTTP 状态和 WebSocket 是否升级；常见代码包括 `AUTH`、`INVALID_REQUEST`、`TRANSPORT`、`TIMEOUT`。
6. 若只看到页面但消息失败，核对 `baseURL`、是否重复 `/v1`、模型 ID、密钥引用和网关协议；不要把 API key 粘进 issue 或日志。

来源：

- [官方仓库](https://github.com/deepseek-ai/deepseek-harness)，目标版本 `v0.2.2-rc.1`。
- [Web 应用部署参考](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/bundle/web-app/README.zh.md#public-deployments)。
- [反向代理部署说明](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/user/guide/public-deployments.zh.md)。
- [DeepSeek Messages 与 endpoint 说明](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/llm/llm-deepseek/README.zh.md#endpoint-and-wire-format)。
- npm 官方元数据：[`@deepseek-ai/dsh@0.2.2-rc.1`](https://registry.npmjs.org/@deepseek-ai%2fdsh/0.2.2-rc.1)。

已核实的关键点：

- 包名是 `@deepseek-ai/dsh`，可执行文件是 `dsh`，Node 最低版本是 `>=24.9.0`。
- npm tarball 的官方 integrity 为 `sha512-ijR9UEVYkG15Q/Q79JzvzLBzQOQfc63VLr9n6flpwHPhr5IKn2UxthnSoto/P9l7qGd7pPvI1Ra6TW7LH3oKpg==`。安装器使用精确版本；npm 的 lock/integrity 校验仍由 npm 完成。
- `dsh --profile web` 默认 loopback、默认端口 3080；生产配置显式固定 `--host 127.0.0.1`。
- `--public-url` 只是公告浏览器看到的根地址；外部 authority 还必须通过 `--trusted-host` 放行。
- 反代必须保留浏览器侧 `Host`、剥离挂载前缀、转发 WebSocket 的 `Upgrade`/`Connection`，并按挂载路径改写 cookie 和裸挂载重定向。
- 启动打印的 `dsh web:` URL 带本进程凭据，只能交给预期用户。`DSH_WEB_URL` 是不带 token 的公告地址。

## 安装

先准备一台已安装 Node `>=24.9.0`、npm、systemd 的 Linux VPS。不要在本文档提供的测试环境或生产机上盲目运行安装器；先审阅变量和生成的 unit。

```sh
sudo DSH_PUBLIC_URL=https://dsh.example.invalid/ \
  DSH_TRUSTED_HOST=dsh.example.invalid \
  ./install.sh
```

可选变量：

- `DSH_USER`（默认 `dsh`）、`DSH_HOME`（默认 `/var/lib/dsh`）、`DSH_PORT`（默认 `3080`）。
- `DSH_TLS_CERT` 与 `DSH_TLS_KEY`：必须同时提供，路径会写入 root-only 的 `/etc/dsh/dsh-web.env`，让 DSH 自己在 loopback 上提供 HTTPS。
- `DSH_ENABLE`（默认 `yes`）：设为 `no` 只安装文件和包，不启动/启用服务。
- `DSH_DRY_RUN`（默认 `no`）：设为 `yes` 只校验参数和脚本自身资源，明确不创建用户、不调用 npm/systemd、不写主机文件。

安装器不会调用 `tailscale funnel`/`tailscale serve`，不会打开端口，不会修改 nftables/iptables，也不会停掉同名以外的服务。它只管理 `dsh-web.service`，且修改前会拒绝覆盖非本项目标记的已有 unit。

## 反向代理配置要点

推荐让反代负责公网 HTTPS，后端保持 `http://127.0.0.1:3080`，并设置：

- `--public-url https://外部主机名/` 与 `--trusted-host 外部主机名`。
- 外部 `Host` 原样转发；如使用 `/dsh/` 前缀，转发前剥离 `/dsh`，同时重写 cookie `Path=/` 为 `Path=/dsh/`。
- 转发 WebSocket 升级头；将 `/dsh` 重定向到 `/dsh/`。
- 反代本身终止 TLS，后端 HTTP 仅限 loopback。

如果必须让 DSH 自身提供 HTTPS，同时设置 `DSH_TLS_CERT`/`DSH_TLS_KEY` 并让反代连接 `https://127.0.0.1:3080`。证书 SAN 必须覆盖浏览器访问的名称，且 key 必须是不加密 PEM 私钥。

## 证书维护边界

反代的 ACME/Serve 证书自动续期，与本机 Harness 的 `--tls-cert`/`--tls-key` 是两个独立生命周期。DSH **不会**申请、续期、监视或自动重新读取本机证书；替换文件后必须执行：

```sh
sudo systemctl reload dsh-web.service || sudo systemctl restart dsh-web.service
```

本 unit 的 `ExecReload` 是 restart，因此证书轮换可由外部续期钩子调用 `systemctl reload dsh-web.service`。如果只在反代终止 TLS，反代的证书续期不会替换任何 Harness 文件，也不需要重启 DSH。

## 登录 URL 工具

工具只接受当前 systemd unit 的主进程身份和本次启动之后的 journal 行：

```sh
sudo -u dsh node --experimental-strip-types tools/login-url.ts --unit dsh-web.service
```

它不读取旧实例、shell 历史、快照或任意日志中的第一条 URL；找不到当前启动凭据时会失败。用 `--public-url` 覆盖生成的外部根地址（例如反代挂载 `/dsh/`），但不会凭空生成 token。

## 续期、重启与排障

```sh
sudo systemctl status dsh-web.service
sudo journalctl -u dsh-web.service -b -n 100 --no-pager
sudo systemctl restart dsh-web.service
sudo systemctl reload dsh-web.service   # unit 中等价于 restart，适合证书轮换
curl -fsS http://127.0.0.1:3080/ >/dev/null
```

- 启动失败：检查 `journalctl`、Node 版本、`dsh` 路径和 env 文件权限；TLS 必须证书和私钥成对且可读。
- 外部 403：检查浏览器可见的 authority 是否同时出现在 `--trusted-host`，以及反代是否保留 `Host`/`Origin`。
- 页面加载但 API/WebSocket 失败：检查路径前缀剥离、cookie `Path` 和升级头。
- 证书更新后仍是旧证书：DSH 只读一次文件，执行 unit reload/restart；不要把反代自动续期误认为本机 Harness 证书自动续期。
- URL 不能登录：用本次 unit 的 `login-url.ts` 重新读取当前启动凭据；不要复用旧 journal 行或旧浏览器 token。

## 安全约束

不要把真实域名、IP、邮件、API key、token、私钥或宿主机配置提交到此仓库。示例域名使用保留的 `.invalid`。公网访问必须使用 HTTPS；loopback 监听不是认证替代品，端口仍应只允许可信本机反代访问。

## 许可证

MIT，见 `LICENSE`。
