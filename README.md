# TouchBarLyrics

在 MacBook Pro 的 **Touch Bar** 上常驻显示当前播放歌曲的歌词(逐行同步滚动),附带 ⏮ ⏯ ⏭ 播放控制。支持网易云音乐、Apple Music 等一切会注册系统"正在播放"的播放器。

仅支持**带 Touch Bar 的 Intel MacBook Pro**(2016–2019 款及 2020 13" M1 之前的 Intel 机型),macOS 13+。已在 macOS Sonoma 14.6 / MacBookPro16,2 上实机验证。

## 功能

- 歌词条固定宽度(360pt,系统对 Touch Bar item 宽度有动态上限,过宽会被清零),歌词逐行滚动;自动按歌名 + 歌手搜索网易云歌词并缓存
- ⏮ ⏯ ⏭ 直接控制系统媒体键,网易云在前台与否都能控制
- Control Strip 常驻 ♪ 按钮:歌词被收起后点击即可重新展开
- 收起:左侧系统圆形 ✕
- 锁屏解锁后自动重新展开
- 开机自启(LaunchAgent)

## 使用

```bash
# 构建并启动
./build.sh
open TouchBarLyrics.app
```

## 开机自启

已通过 LaunchAgent 配置:

```bash
# 查看/加载/卸载
launchctl list | grep touchbarlyrics
launchctl load   ~/Library/LaunchAgents/com.github.alty.touchbarlyrics.plist
launchctl unload ~/Library/LaunchAgents/com.github.alty.touchbarlyrics.plist
```

**注意**:LaunchAgent 里写的是 app 的绝对路径。如果你把 `TouchBarLyrics.app` 移动到别处(比如 `/Applications`),需要修改 `~/Library/LaunchAgents/com.github.alty.touchbarlyrics.plist` 里的 `ProgramArguments` 路径后重新 `launchctl load`。

## 原理与限制

- **播放信息**:`MediaRemote` 私有框架读取系统"正在播放"(歌名/歌手/时长/播放状态)
- **进度插值**:网易云客户端不上报连续进度,只给事件时刻的快照;app 用「快照锚点 + 本地时钟推进」,快照值变化时才重新校准,避免 stale 快照把歌词拖回旧位置
- **歌词来源**:网易云公开 Web API(搜索 + LRC),无需登录;纯音乐/无歌词歌曲显示歌名
- **Touch Bar 接管**:`NSTouchBarItem.addSystemTrayItem`(Control Strip ♪)+ `NSTouchBar.presentSystemModalTouchBar`(全宽接管),均为私有 API,苹果未来系统更新可能使其失效

## 目录

```
src/
  main.m                    入口 + 启动自检
  TBPrivate.h/.m            DFRFoundation 私有 C 函数加载
  TBMediaRemote.h/.m        MediaRemote 桥(通知 + 轮询兜底)
  TBLyrics.h/.m             网易云搜索/歌词 API + LRC 解析 + 缓存
  TBTouchBarController.h/.m Touch Bar UI + 进度插值 + 歌词同步
build.sh                    一键构建(ad-hoc 签名)
```

个人学习用途。
