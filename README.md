# hermes-desktop-portable-update

Hermes Desktop **便携绿色版**客户端的打包与一键更新服务。

## 是什么

一套三件组件，解决「Hermes Desktop 官方安装方式又慢又重」的问题：

| 组件 | 作用 |
|---|---|
| `bin/build-hermes-desktop-asar.sh` | 从 hermes-agent 源码的指定 release tag 构建便携版客户端的 `app.asar`，自动套用自定义补丁，并把更新服务地址/版本号烧进包内 |
| `bin/deploy-hermes-desktop-asar.sh` | 把 `app.asar` 通过 SSH/scp 推到 Windows 客户端机器：停进程 → 换文件 → 重新拉起 |
| `bin/hermes-desktop-update-server.py` | 跑在打包机上的小型 HTTP 服务（纯 stdlib，零依赖），暴露 manifest / 构建 / 状态 / 产物四个端点 |

客户端侧：对 `apps/desktop` 渲染层打补丁（`patches/`），把更新弹窗里「无法连接到更新服务器」的死胡同替换成**「客户端更新（打包服务器）」**面板——显示当前版本 vs 服务器版本，一键触发 构建 → 部署 → 自动重启 的完整流水线。

## 客户端形态

- 绿色免安装：Electron 官方 zip 解包 + 自构建 `app.asar`，不进商店、不装 MSIX，绕开商店应用容器的冷启动。
- 只连远程 Hermes 后端，本机不需要装 CLI / Agent / 任何依赖。
- 更新只替换单个 `resources\app.asar`，连接配置完全不动。

## 配置：不写死任何机器信息

主机名/IP/路径/进程名全部来自本机配置文件，仓库本身不含任何部署细节：

```bash
mkdir -p ~/.config/hermes-desktop-pack
cp config.env.example ~/.config/hermes-desktop-pack/config.env
chmod 600 ~/.config/hermes-desktop-pack/config.env
$EDITOR ~/.config/hermes-desktop-pack/config.env   # 填真实值
```

`config.env` 已被 `.gitignore` 排除。含空格的值要加双引号（shell source 与 systemd `EnvironmentFile` 都认）。可用 `HERMES_PACK_CONFIG` 指向别的配置文件。

## 怎么用

### 一次性部署（打包机，Linux）

```bash
# 1. 源码
git clone --depth 1 https://github.com/NousResearch/hermes-agent.git ~/hermes-desktop-build/hermes-agent

# 2. 脚本
install -Dm755 bin/*.sh bin/*.py ~/bin/
install -Dm644 systemd/hermes-desktop-update.service ~/.config/systemd/user/

# 3. 配置（见上）+ 服务
systemctl --user daemon-reload && systemctl --user enable --now hermes-desktop-update

# 4. 免密 SSH 到客户端机（deploy 依赖），并确认 PACK_SERVER_BASE 从客户端可达
ssh <DEPLOY_HOST> true
```

`PATCH_DIR` 默认指向仓库自带的 `patches/`（克隆本仓库后即可）；也可把 `patches/` 复制到别处并用 config 覆盖。

### 日常升级

- 客户端：状态栏「检查更新」→「一键更新」（构建 → 部署 → 重启全自动）。
- 或手工：`curl -X POST http://<pack-server>:4011/api/desktop-update/build`，轮询 `.../status`。
- 只构建不部署：直接跑 `build-hermes-desktop-asar.sh [tag]`，产物落在 `ART/<tag>/`。

端点：

- `GET  /api/desktop-update/manifest[?tag=vX.Y.Z]` → 最新（或指定）构建的元数据
- `GET  /api/desktop-update/artifact[?tag=…]` → `app.asar` 本体
- `POST /api/desktop-update/build[?tag=…]` → 启动 构建 → 部署 流水线（并发自锁，返回 409）
- `GET  /api/desktop-update/status` → 流水线状态 + 日志尾巴

tag 省略时自动取上游最新稳定版（只认 `v0.x.y` 线，排除 canary 与旧的日期版本号线）。

### 客户端（Windows）

点状态栏「检查更新」→ 弹「客户端更新（打包服务器）」面板：

- 有更新版本 → 「一键更新」→ 进度/日志 → 部署完成客户端自动重启；
- 已是最新 → 显示「已是最新打包版本」。

## 补丁机制

`git checkout -f <tag>` 会清掉 tracked 文件的本地修改，所以补丁持久化为两部分，构建脚本在 checkout 后统一套用：

- `patches/portable-update.patch`：对 `src/store/updates.ts`、`src/app/updates-overlay.tsx` 的 git diff；
- `patches/files/`：新增文件（`portable-updates.ts`、`portable-update-panel.tsx`）的独立副本，构建时直接拷入。

构建时还会生成 `apps/desktop/src/lib/portable-build-tag.ts`，写入本次构建的 tag 与更新服务地址（`package.json` 的 version 是 `0.0.0`，不能用作版本对比）。

上游改动导致 patch 冲突时，对照新源码重做 patch，`git apply --check` 验证后重建（构建脚本 apply 失败会明确告警）。

## 关键坑（踩过的）

1. **探测必须在入口处执行**：Electron 主进程 `hermes:updates:check` 会自己 catch 异常并**正常返回** `{error:'check-failed'}`，渲染层 catch 永不触发，所以打包服务器探测放在 `checkUpdates` 入口而不是 catch 里。
2. **pnpm 走 corepack**：`corepack pnpm`（`COREPACK_ENABLE_DOWNLOAD_PROMPT=0`）；systemd 环境的 PATH 只有系统路径，必须显式给 `NODE_BIN_DIR`。
3. **tag 解析**：`git ls-remote --tags` 剥 `^{}` 用 `sed 's|\^{}$||'`（BRE 里 `\{` 是区间语法，写成 `\{\}` 会报错）。
4. **GUI 拉起**：SSH 会话无法直接起桌面程序，用 `schtasks /IT` 交互任务。
5. **CORS**：服务端发 `Access-Control-Allow-Origin: *`，客户端用无自定义头的简单 POST，避免预检。

## 优势

- **不装任何东西**：客户端零安装、零 CLI、零本地 Agent；打包机只需 git + node/corepack + ssh。
- **秒开**：绕开 MSIX/商店应用容器冷启动。
- **一键更新闭环**：检查 → 构建 → 部署 → 重启全自动。
- **补丁可持久**：自定义修改以 patch 形式跟随每次构建，升级不丢。
- **隐私**：更新服务仅 LAN，流量不出内网；不依赖任何第三方更新通道。
- **零依赖服务端**：纯 Python stdlib 单文件，systemd --user 托管。
- **配置外置**：仓库里没有任何主机名/IP/路径，换机器只改 `config.env`。

## 局限

- 客户端与打包机需同 LAN（或自行加转发）。
- 「设置 → 关于」页内的原生更新卡片未改（只改了更新弹窗）。
- 面板文案硬编码中文。
