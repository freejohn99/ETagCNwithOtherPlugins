# ETagCN with Other Plugins

> 本仓库 Fork 自 [zhy201810576/ETagCN](https://github.com/zhy201810576/ETagCN)，在原版「E-Hentai 中文元数据搜刮」的基础上，新增了多个元数据/登录插件、Venera 扩展与调试、批量补全脚本。
> 仓库地址：[https://github.com/nimalolikong/ETagCNwithOtherPlugins](https://github.com/nimalolikong/ETagCNwithOtherPlugins)

## 简介

本项目是一组面向 [Difegue / LANraragi](https://github.com/Difegue/LANraragi) 的插件合集，适配最新官方 Docker 镜像。

核心 `ETagCN` 插件基于 Difegue 编写的 E-Hentai 插件改良，结合 [EhTagTranslation/Database](https://github.com/EhTagTranslation/Database) 项目提供的中文标签数据库，将 E-Hentai 上的英文标签转换为中文标签。在此基础上，本 Fork 还扩展了哔咔漫画（Picacg）、紳士漫畫（wnacg）、纯文件名/标题标签提取等能力。

原项目是在 ChatGPT 帮助下开发的（作者无 Perl 编程基础），本 Fork 的增量功能在 DeepSeek 协助下完成，可能仍存在未知 BUG。若遇到问题欢迎提交 Issues，也欢迎各位大佬帮忙完善。

## 插件清单

| 插件                  | 类型     | 命名空间        | 版本  | 说明                                                                               |
| --------------------- | -------- | --------------- | ----- | ---------------------------------------------------------------------------------- |
| `ETagCN.pm`         | metadata | `etagcn`      | 2.6.4 | 搜索 E-Hentai/ExHentai，将标签翻译为中文；支持标签库自动更新、从标题提取作者与标签 |
| `TitleTagsCN.pm`    | metadata | `titletagscn` | 1.0.0 | 纯离线，从存档标题（文件名）提取作者、艺术家、团队与括号标签，不改动标题           |
| `PicacgCN.pm`       | metadata | `picacgcn`    | 1.0.0 | 搜索哔咔漫画，反向规范化标签；配合`PicacgLogin.pm` 使用                          |
| `WnacgCN.pm`        | metadata | `wnacgcn`     | 1.0.1 | 搜索紳士漫畫，反向规范化标签；配合`WnacgLogin.pm` 使用                           |
| `source/EHentai.pm` | login    | `ehlogin`     | 2.3   | E-Hentai 登录插件（`ETagCN` 的前置登录插件）                                     |
| `PicacgLogin.pm`    | login    | `picacglogin` | 1.0.0 | 哔咔漫画登录，token 缓存于 UserAgent 供元数据插件复用                              |
| `WnacgLogin.pm`     | login    | `wnacglogin`  | 1.0.1 | 紳士漫畫登录，cookie 缓存于 UserAgent 供元数据插件复用                             |

## 主要新增特性

### ETagCN

- **修复文件名解析**：修复文件名头部有 `gid-` 格式的情况
- **标签数据库自动更新**：从 EhTagTranslation releases 下载最新 `db.text.json`，可设置检查间隔（天）。
- **标题提取**：可从文件名/标题提取作者、艺术家、团队（含 `[团体 (艺术家)]` 形式），并可提取所有括号内容为标签（明显的语言/汉化组会加入 `语言:` / `汉化组:` 命名空间）。

### PicacgCN / WnacgCN

- 按标题、ID/URL 或存档 `source:` 标签搜索对应站点并抓取标签。
- 可选将站点简介写入摘要，获取额外元数据（页数、分类、上传者、点赞、更新时间等）。
- 支持通过 `db.text.json` 反查并规范化标签，与 E-Hentai 刮削结果保持一致的命名空间。

### TitleTagsCN

- 完全离线，仅依据存档标题（文件名）补充标签，不访问网络、不改动标题。
- 适合批量归档时先做一轮基于文件名的标签补全。

## 使用方法（Docker）

1. 下载本仓库插件文件。
2. 将各 `.pm` 文件上传至 LANraragi 的插件目录（每个插件需放在与其包名对应的文件夹中，例如 `ETagCN.pm` 需位于 `ETagCN/ETagCN.pm`）。
3. 按需配置前置登录插件：
   - `ETagCN` / `TitleTagsCN`：配置 `E-Hentai` 登录插件（`source/EHentai.pm`）。
   - `PicacgCN`：配置 `Picacg` 登录插件（`PicacgLogin.pm`）。
   - `WnacgCN`：配置 `紳士漫畫` 登录插件（`WnacgLogin.pm`）。
4. 下载最新的 [EhTagTranslation/Database](https://github.com/EhTagTranslation/Database/releases) 中文标签数据库 **`db.text.json`**，放到 LANraragi 镜像的 `database` 目录下（本仓库根目录也附带了一份 `db.text.json` 可直接使用）。
5. 使用任意文本编辑器打开 `db.text.json`，将 `重新分类` 替换为 `类别`。
6. 打开插件配置，将「EhTagTranslation 的 db.text.json 绝对路径」填写为容器内实际路径，官方 Docker 镜像可填：
   `/home/koyomi/lanraragi/database/db.text.json`
7. 保存插件配置即可。

> 若开启了「自动更新标签数据库」，插件会自行从 EhTagTranslation releases 下载并覆盖该文件，无需手动更新。

## Venera 扩展

`venera_plugins/lanraragi.js` 是一个 [Venera](https://github.com/venera-app/venera) 漫画源扩展（v1.4.0），用于在 Venera 中浏览、搜索与管理 LANraragi 库，支持 API Key 鉴权、随机漫画入口等。

## 调试与辅助脚本（tools/）

| 脚本                      | 说明                                                                                                                                     |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `run_etagcn_batches.py` | 通过 LANraragi 官方 HTTP API，为「没有有效标签」的档案依次尝试`etagcn -> wnacgcn -> picacgcn` 补全中文标签，支持进度续跑与 `--force` |
| `debug_net.pl`          | 在 LANraragi 容器内诊断 E-Hentai / ExHentai 网络连通性与搜索逻辑                                                                         |
| `debug_net_win.pl`      | Windows 本地通过代理验证 E-Hentai 搜索/API 逻辑                                                                                          |
| `debug_picacg.pl`       | 本地验证 PicacgCN / PicacgLogin 的签名与抓取逻辑                                                                                         |
| `debug_wnacg.pl`        | 本地验证 WnacgCN / WnacgLogin 的抓取逻辑                                                                                                 |
| `debug_titletags.pl`    | 纯离线验证 TitleTagsCN 的标题标签提取规则                                                                                                |
| `docker_check_wp.pl`    | 在容器内按真实插件逻辑测试紳士漫畫 / 哔咔漫画插件                                                                                        |

示例：

```bash
# 批量补全（先 dry-run 查看将要处理的档案）
python tools/run_etagcn_batches.py --base-url http://127.0.0.1:3000 --api-key <your_api_key> --dry-run
python tools/run_etagcn_batches.py --base-url http://127.0.0.1:3000 --api-key <your_api_key> --delay 5
```

## 目录结构

```
.
├── ETagCN.pm               # E-Hentai 中文元数据插件（核心）
├── TitleTagsCN.pm          # 文件名/标题标签提取插件
├── PicacgCN.pm             # 哔咔漫画元数据插件
├── PicacgLogin.pm          # 哔咔漫画登录插件
├── WnacgCN.pm              # 紳士漫畫元数据插件
├── WnacgLogin.pm           # 紳士漫畫登录插件
├── source/
│   ├── EHentai.pm          # E-Hentai 登录插件
│   └── EHent.pm            # 备用/历史版本
├── db.text.json            # EhTagTranslation 中文标签数据库
├── venera_plugins/
│   └── lanraragi.js        # Venera 扩展
├── tools/                  # 调试与批量补全脚本
├── main.pl                 # 标签数据库查询示例
└── LICENSE                 # Apache License 2.0
```

## 感谢支持

- [Difegue / LANraragi](https://github.com/Difegue/LANraragi) 及 Difegue 编写的 E-Hentai 插件
- [EhTagTranslation](https://github.com/EhTagTranslation) 项目提供的中文标签数据库
- 原项目作者 [zhy201810576](https://github.com/zhy201810576) 及其 [ETagCN](https://github.com/zhy201810576/ETagCN)

## 许可证

本项目基于 [Apache License 2.0](./LICENSE) 开源。
