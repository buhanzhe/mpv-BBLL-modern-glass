# 第三方来源与许可

| 项目 | 本仓库中的用途 | 许可与来源 |
| --- | --- | --- |
| mpv | 播放器及 Lua 脚本接口，运行时依赖 | [mpv 项目](https://github.com/mpv-player/mpv) · [上游版权和构建许可说明](https://github.com/mpv-player/mpv/blob/v0.42.0/Copyright) |
| akFace/mpv.config | 可搭配使用的 modern_glass 主题及便携配置 | LGPL 2.1 · [项目及许可证](https://github.com/akFace/mpv.config) |
| newBV / BV | B 站 Web 接口、DASH、账号操作和播放心跳的实现参考 | MIT · [newBV](https://github.com/Frost819/newBV) · [BV](https://github.com/aaa1115910/bv) · [许可与版权](licenses/newBV-MIT.txt) |
| uosc_danmaku | 可选的实时弹幕渲染器，本仓库提供对 2.2.0 的接入代码 | MIT · [上游项目](https://github.com/Tony15246/uosc_danmaku) · [许可与版权](licenses/uosc_danmaku-MIT.txt) |
| luaqrcode | `portable_config/scripts/newbv/qrencode.lua`，用于本地生成扫码登录二维码 | BSD 3-Clause · [上游文件固定版本](https://github.com/speedata/luaqrcode/blob/5a9c34bc04d5113048df8528af72ef31d25b7300/qrencode.lua) · [许可与版权](licenses/luaqrcode-BSD-3-Clause.txt) |
| BBLL 1.5.2 | 电视式导航和操作流程的 UI 参考 | 原客户端名称、图标和美术归各自权利人。公开源码的图标使用 Windows 系统字形。 |

仓库根目录的 GPLv3 许可适用于本项目的原创代码。第三方文件依照表中各自的许可，原有版权声明随文件保留。

具备使用权限的自有或第三方素材可放在本地安装的 `newbv` 目录中。PNG 放在 `bbll-assets/`，播放器图标 SVG 放在 `bbll-vectors/`。可选的导航矢量定义和任务栏图标分别读取 `bbll-icons.json` 和 `bbll-launcher.png.base64`。
