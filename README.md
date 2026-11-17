# hermes-desktop-portable-update

Hermes Desktop **便携绿色版**客户端的打包与更新（GitHub Actions + Releases）。

## 是什么

官方安装方式重且慢（MSIX / 安装器 / 应用容器冷启动）。这里用「Electron 官方 zip 解包 + 自构建 `app.asar`」得到一个绿色客户端：不进商店、不安装、只替换单个 `resources/app.asar` 即可升级。

| 组件 | 作用 |
|---|---|
| `.github/workflows/build-asar.yml` | 在 GitHub Actions 上从 hermes-agent 的 release tag 构建 `app.asar`，套用补丁，发布到本仓库 Release |
| `bin/build-hermes-desktop-asar.sh` | 同上，但可在任意有 node/pnpm 的机器本地跑（CI 复用的就是它） |
| `bin/install-hermes-desktop-linux.sh` | Linux x64 一键安装/更新：`/opt/hermes-desktop` + `/usr/bin/hermes-desktop` + 桌面入口 |
| `patches/` | 客户端更新面板补丁（把「无法连接更新服务器」换成版本比较 + 下载入口） |

## 客户端形态

- 绿色：Electron 官方 zip 解包 + 自构建 `app.asar`，不写系统目录（除 `/opt` 与两个软链）。
- 只连远程 Hermes 后端，本机不需要 CLI / Agent。
- 更新 = 换 `resources/app.asar`，连接配置不动。
- 更新源是 GitHub Releases，不依赖任何内网服务。

## 安装（Linux x64）

```bash
curl -fsSL https://github.com/Chonghua-05/hermes-desktop-portable-update/releases/latest/download/install-hermes-desktop-linux.sh | bash
```

装完运行 `hermes-desktop`。重复执行同一条命令即更新（Electron 已存在会跳过，只换 asar）。

安装布局：

```
/opt/hermes-desktop/            应用目录（属主为当前用户，更新不需要 root）
  electron                      Electron 44.9.3 运行时
  resources/app.asar            应用本体 = 唯一更新点
  hermes-desktop                启动器（Wayland 会话走原生 Wayland）
/usr/bin/hermes-desktop         -> 上面的启动器
/usr/share/applications/hermes-desktop.desktop
```

可用环境变量覆盖：`DEST`、`BIN_DIR`、`APPS_DIR`、`ELECTRON_VER`、`ASAR_URL`、`ASAR_MANIFEST_URL`、`REPO_SLUG`。

asar 用 manifest 里的 `sha256` 校验；拿不到 manifest 时跳过校验并如实提示。

## 构建（GitHub Actions）

两条触发路径：**每天 03:00 UTC 的 schedule**（自动跟进上游最新的 `v0.x.y`；若该版本已发过 Release 直接跳过，空闲日只花几秒），以及 Actions → **Build app.asar** → Run workflow 手动跑：

- `upstream_tag`：要打包的上游 tag，留空 = 最新稳定版（只认 `v0.x.y`，排除 canary 与旧日期线）；
- `publish`：是否发布 Release（关掉就只留 workflow artifact；schedule 触发时恒为发布）。

`probe` job 先把 tag 解析出来并判断是否已有 `asar-<tag>` Release，`build` job 只在需要时才跑。

产物是一个 Release（tag 形如 `asar-v0.23.2`），含四个附件：

- `app.asar`
- `app.asar.unpacked.tar.gz`（原生模块，必须一起落地）
- `manifest.json`（tag / upstreamTag / version / builtAt / sha256 / unpackedSha256 / size）
- `install-hermes-desktop-linux.sh`

并把该 Release 标记为 latest，所以 `releases/latest/download/...` 这些 URL 永远指向最新版本，不需要随版本改。

## 构建（本地）

```bash
git clone --depth 1 https://github.com/NousResearch/hermes-agent.git ~/hermes-desktop-build/hermes-agent
bin/build-hermes-desktop-asar.sh            # 最新稳定版
bin/build-hermes-desktop-asar.sh v0.23.1    # 指定 tag
```

产物落在 `$ART/<tag>/`（默认 `~/hermes-desktop-artifacts`）。可选的 `config.env`（见 `config.env.example`，已被 .gitignore 排除）只用来覆盖路径与 release 目标。

## 补丁机制

`git checkout -f <tag>` 会清掉 tracked 文件的本地修改，所以补丁持久化为两部分，构建脚本在 checkout 后统一套用：

- `patches/portable-update.patch`：对 `src/store/updates.ts`、`src/app/updates-overlay.tsx` 的 git diff；
- `patches/files/`：新增文件（`portable-updates.ts`、`portable-update-panel.tsx`）的独立副本，构建时直接拷入。

构建时还生成 `apps/desktop/src/lib/portable-build-tag.ts`，写入本次 tag、Release API 地址与 Release 页面地址（`package.json` 的 version 是 `0.0.0`，不能用作版本对比）。

上游改动导致 patch 冲突时，对照新源码重做 patch，`git apply --check` 验证后重建（构建脚本 apply 失败直接退出，不产出半成品）。

## 客户端更新面板

绿色版没有官方 updater，设置里的「检查更新」必然报 `check-failed`。补丁在此处接管：

- 拉 `https://api.github.com/repos/<owner>/<repo>/releases/latest`，取 `tag_name` 与 `app.asar` 附件；
- 比较后果显示当前版本 / 最新版本，给「打开下载页」和「复制更新命令」；
- 客户端不自建、不自部署——构建发生在 CI，安装/更新由上面那条命令完成。

## 关键坑（踩过的）

1. **探测必须在入口处执行**：Electron 主进程 `hermes:updates:check` 会自己 catch 异常并**正常返回** `{error:'check-failed'}`，渲染层 catch 永不触发，所以探测放在 `checkUpdates` 入口而不是 catch 里。
2. **pnpm 走 corepack**：`corepack pnpm`，并设 `COREPACK_ENABLE_DOWNLOAD_PROMPT=0`；非交互环境（systemd/CI）的 PATH 要给全 `NODE_BIN_DIR`。
3. **tag 解析**：`git ls-remote --tags` 剥 `^{}` 用 `sed 's|\^{}$||'`（BRE 里 `\{` 是区间语法，写成 `\{\}` 会报错）。
4. **asar 与 Electron 版本**：asar 里的原生模块（`node-pty`）随构建机平台走。CI 在 ubuntu 上只编出 Linux 的 `pty.node`，Windows 客户端要靠 `node-pty` 自带的 win32 prebuilds：`lib/utils.js` 的加载顺序是 `build/Release` → `build/Debug` → `prebuilds/<platform>-<arch>`，逐个 try/catch，所以把 npm 包里的 `prebuilds/win32-*`（conpty.node、conpty.dll、OpenConsole.exe、winpty）一起塞进 `app.asar.unpacked`，Windows 上就会跳过加载失败的 Linux ELF 落到 prebuilds。**别用 `find -name pty.node | head -1` 取二进制做检查**：加了 prebuilds 后会先命中 PE 文件，`objdump` 直接报错——按 `*/build/Release/pty.node` 这种完整路径取。
5. **Chromium 沙箱**：解包版 `chrome-sandbox` 必须是 `root:root` + `4755`，否则只能 `--no-sandbox`。安装脚本会设置它。
6. **Wayland**：Electron 42+ 默认 `--ozone-platform=auto`，启动器在 Wayland 会话下显式给 `--ozone-platform=wayland`。

## 局限

- 只提供 Linux x64 安装脚本；Windows 客户端需手动替换 `resources\app.asar`（该文件运行时被占用，需先退出客户端）。
- 「设置 → 关于」页内的原生更新卡片未改（只改了更新弹窗）。
- 面板文案硬编码中文。
- 未打包成发行版安装包（deb/rpm/AppImage），只做绿色目录。
