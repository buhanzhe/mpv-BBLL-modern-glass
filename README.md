# mpv BBLL modern glass

给 Windows 版 mpv 增加一个电视式 B 站选片窗口，可与 modern_glass 主题一起使用。选片界面使用 WPF，播放交给 mpv。

## 功能

- 首页推荐、搜索、分区、直播、视频详情、选集、评论和回复。
- 在选片窗口扫码登录，查看历史、收藏、稍后再看和关注。登录后，普通视频及剧集会定期上报观看进度，切换或关闭视频时会尝试保存最后的进度。
- 优先选择可用的高画质，记住手动选择的画质和编码。视频有对应音轨时可选 Hi-Res FLAC 或 Dolby E-AC-3。
- 播放时保留选片页面。窗口支持标题区拖动、边缘缩放、右键返回及最小化、全屏和关闭。
- 接入 `uosc_danmaku 2.2.0` 后，可在选片设置中实时调整字号、速度、透明度、占屏比、同屏数量及悬停弹幕。

## 安装

准备 Windows 10 或 11、Windows PowerShell 5.1 和支持 `mp.input` 的 Windows 版 mpv。本项目用 mpv 0.42.0 验证。需要播放器主题时，可先下载 modern_glass 便携配置。 [mpv 下载](https://mpv.io/installation/)，[akFace/mpv.config](https://github.com/akFace/mpv.config)

在本仓库目录运行下面的命令，将示例路径换成你自己的 mpv 目录。

```powershell
$mpvRoot = 'C:\Apps\mpv'
$portable = Join-Path $mpvRoot 'portable_config'
$scripts = Join-Path $portable 'scripts'
New-Item -ItemType Directory -Force -Path $scripts | Out-Null
Copy-Item -LiteralPath '.\portable_config\scripts\newbv' -Destination $scripts -Recurse -Force
```

如已安装 `uosc_danmaku 2.2.0`，可在重启 mpv 前运行以下命令启用弹幕实时设置。

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\install-danmaku.ps1 -PortableConfig $portable
```

启动 mpv 后按 `Alt+B` 打开选片窗口。若 `portable_config/mpv.conf` 启用了以下配置，空启动时会自动打开选片窗口。

```ini
idle=yes
force-window=immediate
```

如需关闭自动打开，可在 `portable_config/script-opts/newbv.conf` 写入 `autobrowse=no`。播放本地视频时也可以使用 `Alt+B` 打开选片窗口。

## 操作

| 快捷操作 | 功能 |
| --- | --- |
| `Alt+B` | 打开或唤回选片窗口 |
| `Alt+L` | 打开选片窗口里的扫码登录页 |
| `Alt+Q` | 切换当前视频的画质或直播线路 |
| `Alt+P` | 打开播放控制栏 |
| `Alt+I` / `Alt+C` | 打开当前视频详情 / 评论 |
| 右键 / `Esc` | 在选片窗口逐层返回 |

扫码在本机生成。会话通过 Windows DPAPI 加密保存在当前 Windows 用户的 `%LOCALAPPDATA%\mpv-newbv\session.dpapi`，画质偏好和选片设置也保存在用户目录。可从头像菜单退出本机登录。B 站的内容、画质和账号权限以平台响应为准。

## 开发验证

```powershell
powershell.exe -NoProfile -File .\tests\test_newbv.ps1
powershell.exe -NoProfile -STA -File .\tests\test_newbv_browser.ps1 -CheckLayout
```

第一项使用离线数据验证接口参数和会话处理。第二项需要联网，在真实 WPF 窗口验证导航、窗口按钮及连续选片。

## 许可与致谢

原创代码采用 [GNU GPL v3](LICENSE)（`GPL-3.0-only`）。Copyright (C) 2026 buhanzhe and contributors.

第三方组件、接口参考和 UI 参考及各自许可见 [THIRD_PARTY.md](THIRD_PARTY.md)。公开源码使用 Windows 系统字形和本项目的 XAML，播放器及主题请从各自上游安装。
