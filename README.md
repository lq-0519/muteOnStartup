# MuteOnStartup · 启动静音

一个轻量的 macOS 后台工具，在登录和睡眠唤醒后自动静音 MacBook 内置扬声器，避免电脑仍保留昨晚看电影、听音乐时的音量，第二天打开就突然发出声音。

如果登录或唤醒发生在上午 06:30～12:00，还会将系统切回浅色模式，方便从晚间使用状态切换到白天工作状态。

## 主要功能

- 登录用户会话后执行一次静音检查。
- 每次睡眠唤醒后延迟 3 秒检查，等待音频设备恢复。
- 只静音识别到的 MacBook 内置扬声器，不静音外置耳机、蓝牙耳机或显示器音频。
- 已静音或音量为零时跳过，实际执行静音后才显示通知。
- 上午登录或唤醒时关闭深色模式及自动切换外观。
- 以用户级 LaunchAgent 在后台运行，等待系统事件，不定时轮询。

它在用户会话启动后生效，不能关闭 macOS 在登录前播放的启动提示音。浅色模式只在登录 / 唤醒事件时检查，不会在每天 06:30 定时触发。

## 环境与安装

- macOS 13 或更新版本。
- Swift 5.9 或更新版本及 Xcode Command Line Tools。
- 使用 Swift、CoreAudio 和系统通知等框架，无第三方包依赖。

在项目目录执行：

```bash
./scripts/install.sh
```

脚本构建并安装后台应用，随后注册、启动用户级 LaunchAgent：

```text
~/Library/Application Support/MuteOnStartup/MuteOnStartup.app
~/Library/LaunchAgents/local.mute-on-startup.plist
```

应用图标使用仓库中的 [AppIcon.icns](assets/AppIcon.icns)。当前安装脚本使用 ad-hoc 签名；重新运行脚本会更新安装并重启后台服务。

## 日常使用

安装后无需打开窗口或手动操作。登录及唤醒时自动检查内置扬声器；只有检测到需要静音并完成操作后，才提示“已静音 MacBook Pro 扬声器”。

上午浅色模式采用本地时间范围 `06:30 <= 当前时间 < 12:00`，并关闭系统“自动切换外观”。当前版本的静音行为不修改麦克风输入音量。

需要立刻静音一次时，可以运行：

```bash
./scripts/mute-now.sh
```

## 查看状态与日志

```bash
launchctl print "gui/$(id -u)/local.mute-on-startup"
tail -f "$HOME/Library/Logs/MuteOnStartup/agent.err.log"
```

后台进程平时等待系统事件。LaunchAgent 使用较低调度优先级和 30 秒重启节流，避免异常退出时频繁重启。

## 常见问题

**为什么蓝牙耳机没有被静音？** 当前目标是内置扬声器，外部输出设备保留原来的音量。

**没有看到静音通知？** 内置扬声器已经静音或音量为零时会直接跳过。也可以检查系统通知设置中是否关闭了“启动静音”。

**上午没有切换浅色模式？** 需要在该时间范围内发生登录或唤醒事件，后台服务也必须已运行。若系统请求允许控制“系统事件”，需允许该自动化操作。

**麦克风曾被旧版本调到零？** 仓库保留一次性恢复脚本，手动运行后默认将输入音量恢复为 80；此脚本会实际修改输入音量：

```bash
./scripts/restore-mic.sh
# 也可指定恢复值
./scripts/restore-mic.sh 100
```

## 卸载

```bash
./scripts/uninstall.sh
```

实现入口为 [main.swift](Sources/MuteOnStartupAgent/main.swift)，安装与卸载入口位于 [scripts](scripts)。

这个个人效率工具主要通过 AI 辅助开发，作为 macOS 原生小工具的实践项目。
