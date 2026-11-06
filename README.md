# DSH VPS 部署（0.2.2-rc.1）

这是一套面向 VPS 的、可重入的 DeepSeek Harness（DSH）Web 部署记录与辅助文件。它把 Web GUI 保持在本机 loopback，通过已有的 HTTPS 反向代理提供外部访问；不启用 Funnel，不修改防火墙，也不覆盖宿主机已有服务。

> 版本边界：本文和脚本固定 `@deepseek-ai/dsh@0.2.2-rc.1`。官方仓库当前 `package.json` 声明 Node `>=24.9.0`，请不要用旧 Node 猜测安装结果。

## 目录

- `install.sh`：最小、幂等安装器；只在 root 下运行，默认创建 `dsh` 独立用户、安装固定 npm 包并生成 unit。
- `systemd/dsh-web.service.in`：systemd 模板。服务只绑定 `127.0.0.1`，不负责反代、证书签发或防火墙。
- `tools/login-url.ts`：从当前 systemd 主进程对应的本次启动日志读取最新启动凭据，并把它换算为正确的外部 URL。
- `tests/test.sh`：不触碰宿主服务的 shell 静态检查与隔离 mock 测试。

## 官方事实核对

来源：

- [官方仓库](https://github.com/deepseek-ai/deepseek-harness)，目标版本 `v0.2.2-rc.1`。
- [Web 应用部署参考](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/bundle/web-app/README.zh.md#public-deployments)。
- [反向代理部署说明](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/user/guide/public-deployments.zh.md)。
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
