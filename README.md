# 启动静音

一个很小的 macOS 用户态后台 agent：开机登录时自动静音，电脑从睡眠中唤醒时也自动静音。

## 方案选择

这个场景更适合用 `LaunchAgent + 小型 Swift 后台进程`，不太需要做成完整 App，也不适合定时脚本。

- 完整 App 适合做菜单栏开关、偏好设置、分设备配置这类交互。
- 纯 shell 脚本可以做到登录时静音，但要可靠感知“唤醒”事件就容易变成轮询或依赖额外工具。
- 当前实现会在用户会话里常驻，启动时静音一次，并监听 macOS 原生唤醒通知；每次唤醒后延迟 3 秒静音一次，等待音频设备恢复，不做 1 秒、5 秒后的多次重试。

## 静音范围

agent 会静音当前默认输出设备和系统音效输出设备。它不会调整麦克风输入音量，避免影响语音输入法、外置耳机麦克风或电脑自带麦克风。

静音成功后，会发一条系统通知提示“已将系统静音”。

如果通知没有出现，可以到系统设置的通知列表里查看“启动静音”是否被关闭。

它在用户会话启动后生效，所以不能处理 macOS 加载用户 LaunchAgent 之前发生的登录前启动提示音。

## 安装

```sh
./scripts/install.sh
```

安装脚本会构建 Swift 可执行文件，并放到一个后台 `.app` bundle 中：

```text
~/Library/Application Support/MuteOnStartup/MuteOnStartup.app
```

这个 app bundle 会使用 [assets/AppIcon.icns](/Users/bytedance/Documents/muteOnStartup/assets/AppIcon.icns) 作为通知和应用图标。

同时注册这个 LaunchAgent：

```text
~/Library/LaunchAgents/local.mute-on-startup.plist
```

## 手动静音一次

```sh
./scripts/mute-now.sh
```

## 恢复麦克风输入音量

历史版本曾经会把麦克风输入音量也设为 `0`。如果语音输入法、外置耳机麦克风或电脑自带麦克风收音异常，可以手动恢复一次输入音量：

```sh
./scripts/restore-mic.sh
```

默认会把麦克风输入音量恢复到 `80`。也可以指定其他值：

```sh
./scripts/restore-mic.sh 100
```

## 查看状态

```sh
launchctl print "gui/$(id -u)/local.mute-on-startup"
tail -f "$HOME/Library/Logs/MuteOnStartup/agent.err.log"
```

## 资源占用

agent 不做定时轮询，平时只挂在系统 RunLoop 上等待启动和唤醒事件。空闲时 CPU 应该接近 `0.0%`。

安装脚本会把 LaunchAgent 标记为后台进程，并设置较低调度优先级、低优先级 IO 和 30 秒重启节流，避免异常情况下频繁重启占用资源。

## 卸载

```sh
./scripts/uninstall.sh
```
