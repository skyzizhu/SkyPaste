# SkyPaste for Windows（Windows 10 / Windows 11）

SkyPaste 的 Windows 版本：剪贴板历史管理器，支持文本、链接、图片、文件、文件夹、代码、邮箱的保存、搜索、预览、收藏与局域网同步。与 macOS 版（本仓库上层目录）功能对应，架构独立。

## 功能一览

- **剪贴板历史**：文本、链接、图片、文件、文件夹、代码、邮箱自动分类；来源应用徽标；按天分组
- **筛选器**：全部 / 文本 / 图片 / 文件 / 目录 / 代码 / URL / 邮箱 / 收藏，支持右键移动与拖拽排序，顺序持久化
- **搜索**：大小写不敏感子串匹配 + 中文关键词索引 + 搜索语法：
  - `type:text / type:image / type:file / type:folder / type:code / type:url / type:email`
  - `source:local / source:device`
  - `fav|收藏`（仅收藏）、`today|今天`、`yesterday|昨天`
  - 多词 AND 匹配
- **快捷键**：`Ctrl+Shift+V`（可配置 A–Z + Ctrl/Shift/Alt/Win）呼出主面板
  - `Enter` 粘贴（或复制，取决于设置）、`Ctrl+C` 复制、`Ctrl+1...9` 快捷复制第 N 项
  - `↑/↓` 导航、`Esc` 关闭面板
- **粘贴回原应用**：复制后自动切回之前的窗口并注入 `Ctrl+V`（可在设置关闭，改为"选中即复制"）
- **图片预览**：0.4–5× 缩放平移、双击 3×、按 Ctrl+滚轮缩放、画笔标注（5 色、2–12 宽、撤销/清除）、标注后按原始分辨率导出 PNG
- **文件详情**：信息（名称/类型/大小/修改时间/路径）、目录内容列表、图片文件双视图（信息 ↔ 预览）、缺失路径提示
- **批量操作**：全选 / 收藏 / 取消收藏 / 删除
- **剪贴板统计**：今日 / 7 天 / 30 天 / 6 个月 / 1 年五档，复制趋势、类型分布、来源应用统计
- **隐私过滤**：忽略密码管理器内容、验证码、银行卡号（Luhn 校验）、API Token/JWT/私钥类敏感文本
- **忽略应用**：按进程名或应用名忽略（如 `1password.exe`）
- **主题**：跟随系统 / 浅色 / 深色；**6 语言**：English / 简体中文 / 繁體中文 / 日本語 / 한국어 / Français
- **托盘图标**：左键弹出轻量剪贴板列表（80 条以内），右键菜单打开面板/统计/设置/退出
- **局域网同步**（替代 macOS 的 iCloud 同步，见下文）
- **本地存储**：`%APPDATA%\SkyPaste\`（`history.sqlite` + `statistics.sqlite` + `settings.json`），损坏自动备份恢复

## 局域网同步：手机 → Windows

SkyPaste 在局域网内开放一个带令牌校验的 HTTP 服务（默认端口 **26177**），手机上的剪贴板内容可以推送到 Windows：

1. 在 SkyPaste 设置里开启 **局域网同步**（可分别控制"上传本机文本"与"接收设备内容"）
2. 在设置中查看 **配对令牌**（`X-SkyPaste-Token`）与本机 IP（`ipconfig` 查看）
3. 手机端推送：

### iOS（快捷指令 / Shortcuts）

新建快捷指令：
1. **获取剪贴板**（Get Clipboard）
2. **获取 URL 内容**（Get Contents of URL）：
   - URL：`http://<电脑IP>:26177/paste`
   - 方法：`POST`
   - Header：`X-SkyPaste-Token` = 设置里显示的令牌
   - Request Body：JSON：`{"text": "剪贴板", "device": "iPhone"}`
3. （可选）把该快捷指令加入辅助功能「轻点背面」或主屏幕

> 发送图片：Body 使用 `{"imageBase64": "<base64>", "name": "photo.png", "device": "iPhone"}`。

### Android

- **Tasker / HTTP Requester**：向 `http://<电脑IP>:26177/paste` 发 POST，Header 同上，Body 为 JSON
- 也可用任意支持"分享到 HTTP"的工具

### Windows ↔ Windows

两台运行 SkyPaste 的电脑在同一局域网会通过 UDP 广播（端口 26178）自动发现彼此，并每 10 秒互拉新增文本（与 macOS 版 iCloud 同步一致的冲突策略：按时间戳新者胜、指纹去重、删除不传播）。

## 从源码构建

要求：.NET 8 SDK（Windows / macOS / Linux 均可构建，Windows 才能运行）

```bash
cd SkyPasteWindows
dotnet build SkyPaste.sln
dotnet test tests/SkyPaste.Tests/SkyPaste.Tests.csproj

# 发布单文件 exe（自包含，无需安装 .NET）
dotnet publish src/SkyPaste/SkyPaste.csproj -c Release -r win-x64 --self-contained true \
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o publish
```

CI：`.github/workflows/windows-build.yml` 在 windows-latest 上自动构建 + 测试 + 发布 zip 工件（Actions 页面可下载）。

## 目录结构

```
SkyPasteWindows/
├── SkyPaste.sln
├── .github/workflows/windows-build.yml
├── scripts/                 # make_icon.py / make_resx.py（生成资产）
├── src/SkyPaste.Core/       # 可移植核心：模型、分类、搜索、指纹、敏感过滤、
│                            # SQLite 存储、统计、设置、局域网同步、本地化（6 语言 resx）
├── src/SkyPaste/            # WPF 壳：Win32 互操作、剪贴板监听/读写、热键、粘贴回、
│                            # 托盘、主题、拖拽、另存为、预览/主面板/设置/统计/调试窗口
└── tests/SkyPaste.Tests/    # xUnit 单元测试（93 个）
```

## 与 macOS 版的差异

| macOS | Windows |
|---|---|
| iCloud CloudKit 同步（仅 Mac 间） | 局域网 HTTP + UDP 同步（手机与 PC 均可推送） |
| 通用剪贴板（iPhone 系统级） | 快捷指令/HTTP 推送方案 |
| Cmd+Shift+V / Cmd+C / Cmd+1..9 | Ctrl+Shift+V / Ctrl+C / Ctrl+1..9 |
| NSPasteboard 逐格式快照 | CF_HDROP / CF_DIB / CF_UNICODETEXT |
| 分享面板、系统翻译 | 无系统级等价物，暂未提供 |
| 登录自启 SMAppService | 注册表 Run 键 |

## 隐私

所有数据保存在本机 `%APPDATA%\SkyPaste\`。局域网同步默认关闭；开启后仅接受携带配对令牌的请求，不上传任何内容到云端。

## License

[MIT](../LICENSE)
