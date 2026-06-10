import AppKit
import CoreAudio
import Dispatch
import Foundation

private var signalSources: [DispatchSourceSignal] = []
private var notificationObservers: [NSObjectProtocol] = []
private var pendingWakeAction: DispatchWorkItem?
private let wakeMuteDelay: TimeInterval = 3.0

private enum AgentMode {
    case daemon
    case once
    case help

    init(arguments: [String]) {
        if arguments.contains("--help") || arguments.contains("-h") {
            self = .help
        } else if arguments.contains("--once") {
            self = .once
        } else {
            self = .daemon
        }
    }
}

private enum Log {
    static func info(_ message: String) {
        write("INFO", message)
    }

    static func error(_ message: String) {
        write("ERROR", message)
    }

    private static func write(_ level: String, _ message: String) {
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
        FileHandle.standardError.write(Data("[\(timestamp)] \(level): \(message)\n".utf8))
    }
}

private final class NotificationDelegate: NSObject, NSUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: NSUserNotificationCenter,
        shouldPresent notification: NSUserNotification
    ) -> Bool {
        true
    }
}

private enum SystemNotifier {
    private static let delegate = NotificationDelegate()

    static func showMutedNotification() {
        let center = NSUserNotificationCenter.default
        center.delegate = delegate

        let notification = NSUserNotification()
        notification.title = "启动静音"
        notification.informativeText = "已将系统静音。"
        center.deliver(notification)
    }
}

private enum CoreAudioMuter {
    private static let outputScope = AudioObjectPropertyScope(kAudioDevicePropertyScopeOutput)
    private static let mainElement = AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
    private static let elementsToTry = [mainElement] + (1...8).map(AudioObjectPropertyElement.init)

    struct Result {
        let changed: Bool
        let details: [String]
    }

    static func muteCurrentOutputs() -> Result {
        var seenDevices = Set<AudioObjectID>()
        var details: [String] = []
        var changed = false

        let selectors: [(AudioObjectPropertySelector, String)] = [
            (AudioObjectPropertySelector(kAudioHardwarePropertyDefaultOutputDevice), "default-output"),
            (AudioObjectPropertySelector(kAudioHardwarePropertyDefaultSystemOutputDevice), "system-output")
        ]

        for (selector, label) in selectors {
            guard let deviceID = readDeviceID(selector: selector, label: label) else {
                details.append("\(label): no device")
                continue
            }

            guard deviceID != AudioObjectID(kAudioObjectUnknown) else {
                details.append("\(label): unknown device")
                continue
            }

            if !seenDevices.insert(deviceID).inserted {
                continue
            }

            let deviceResult = muteDevice(deviceID)
            changed = changed || deviceResult.changed
            details.append("\(label): device \(deviceID), \(deviceResult.details.joined(separator: ", "))")
        }

        return Result(changed: changed, details: details)
    }

    private static func readDeviceID(
        selector: AudioObjectPropertySelector,
        label: String
    ) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: mainElement
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        if status != noErr {
            Log.error("failed to read \(label) device: OSStatus \(status)")
            return nil
        }

        return deviceID
    }

    private static func muteDevice(_ deviceID: AudioObjectID) -> Result {
        var details: [String] = []
        var changed = false

        for element in elementsToTry {
            if setFloat32Property(
                selector: AudioObjectPropertySelector(kAudioDevicePropertyVolumeScalar),
                deviceID: deviceID,
                element: element,
                value: 0
            ) {
                changed = true
                details.append("volume element \(element)=0")
            }

            if setUInt32Property(
                selector: AudioObjectPropertySelector(kAudioDevicePropertyMute),
                deviceID: deviceID,
                element: element,
                value: 1
            ) {
                changed = true
                details.append("mute element \(element)=1")
            }
        }

        if details.isEmpty {
            details.append("no settable output volume/mute property")
        }

        return Result(changed: changed, details: details)
    }

    private static func setFloat32Property(
        selector: AudioObjectPropertySelector,
        deviceID: AudioObjectID,
        element: AudioObjectPropertyElement,
        value: Float32
    ) -> Bool {
        var mutableValue = value
        return setProperty(
            selector: selector,
            deviceID: deviceID,
            element: element,
            size: UInt32(MemoryLayout<Float32>.size),
            value: &mutableValue
        )
    }

    private static func setUInt32Property(
        selector: AudioObjectPropertySelector,
        deviceID: AudioObjectID,
        element: AudioObjectPropertyElement,
        value: UInt32
    ) -> Bool {
        var mutableValue = value
        return setProperty(
            selector: selector,
            deviceID: deviceID,
            element: element,
            size: UInt32(MemoryLayout<UInt32>.size),
            value: &mutableValue
        )
    }

    private static func setProperty<T>(
        selector: AudioObjectPropertySelector,
        deviceID: AudioObjectID,
        element: AudioObjectPropertyElement,
        size: UInt32,
        value: inout T
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: outputScope,
            mElement: element
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            return false
        }

        var isSettable = DarwinBoolean(false)
        let settableStatus = AudioObjectIsPropertySettable(deviceID, &address, &isSettable)
        guard settableStatus == noErr, isSettable.boolValue else {
            return false
        }

        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value)
        if status != noErr {
            Log.error("failed to set CoreAudio property \(selector) on device \(deviceID), element \(element): OSStatus \(status)")
            return false
        }

        return true
    }
}

private enum VolumeMuter {
    static func mute(reason: String) {
        let result = CoreAudioMuter.muteCurrentOutputs()
        if result.changed {
            Log.info("muted output volume for \(reason): \(result.details.joined(separator: "; "))")
            SystemNotifier.showMutedNotification()
        } else {
            Log.error("did not find a settable output volume/mute control for \(reason): \(result.details.joined(separator: "; "))")
        }
    }
}

private enum MorningWindow {
    private static let startMinuteOfDay = 6 * 60 + 30
    private static let endMinuteOfDay = 12 * 60

    static func contains(_ date: Date = Date(), calendar: Calendar = .current) -> Bool {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = components.hour, let minute = components.minute else {
            return false
        }

        let minuteOfDay = hour * 60 + minute
        return minuteOfDay >= startMinuteOfDay && minuteOfDay < endMinuteOfDay
    }
}

private enum AppearanceManager {
    private static let appearanceKey = "AppleInterfaceStyle" as CFString
    private static let themeChangedNotification = Notification.Name("AppleInterfaceThemeChangedNotification")

    static func disableDarkModeDuringMorning(reason: String) {
        guard MorningWindow.contains() else {
            Log.info("skipped light appearance for \(reason): outside 06:30-12:00")
            return
        }

        let hosts = [
            kCFPreferencesAnyHost,
            kCFPreferencesCurrentHost
        ]
        let previousStyles = hosts.compactMap { host -> String? in
            guard let style = CFPreferencesCopyValue(
                appearanceKey,
                kCFPreferencesAnyApplication,
                kCFPreferencesCurrentUser,
                host
            ) as? String else {
                return nil
            }

            return "\(host)=\(style)"
        }

        for host in hosts {
            CFPreferencesSetValue(
                appearanceKey,
                nil,
                kCFPreferencesAnyApplication,
                kCFPreferencesCurrentUser,
                host
            )
        }

        let synchronized = hosts
            .map { CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, $0) }
            .allSatisfy { $0 }

        DistributedNotificationCenter.default().post(
            name: themeChangedNotification,
            object: nil
        )

        if synchronized {
            let previousDescription = previousStyles.isEmpty ? "unset" : previousStyles.joined(separator: ", ")
            Log.info("applied light appearance for \(reason): previous AppleInterfaceStyle=\(previousDescription)")
        } else {
            Log.error("requested light appearance for \(reason), but CFPreferencesSynchronize returned false")
        }
    }
}

private enum StartupActions {
    static func run(reason: String) {
        VolumeMuter.mute(reason: reason)
        AppearanceManager.disableDarkModeDuringMorning(reason: reason)
    }

    static func scheduleWakeMute(reason: String) {
        pendingWakeAction?.cancel()

        let workItem = DispatchWorkItem {
            run(reason: reason)
        }
        pendingWakeAction = workItem

        Log.info("scheduled wake actions for \(reason) in \(wakeMuteDelay)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + wakeMuteDelay, execute: workItem)
    }
}

private func installTerminationHandlers() {
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)

    let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    termSource.setEventHandler {
        Log.info("received SIGTERM, exiting")
        exit(0)
    }
    termSource.resume()
    signalSources.append(termSource)

    let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    intSource.setEventHandler {
        Log.info("received SIGINT, exiting")
        exit(0)
    }
    intSource.resume()
    signalSources.append(intSource)
}

private func printHelp() {
    print("""
    mute-on-startup-agent

    Usage:
      mute-on-startup-agent            Run as a wake/listen daemon.
      mute-on-startup-agent --once     Mute output and alert volume once.
      mute-on-startup-agent --help     Show this help.
    """)
}

private let mode = AgentMode(arguments: Array(CommandLine.arguments.dropFirst()))

switch mode {
case .help:
    printHelp()

case .once:
    VolumeMuter.mute(reason: "manual")
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))

case .daemon:
    installTerminationHandlers()
    StartupActions.run(reason: "agent-start")

    let workspaceNotifications = NSWorkspace.shared.notificationCenter
    let wakeObserver = workspaceNotifications.addObserver(
        forName: NSWorkspace.didWakeNotification,
        object: nil,
        queue: .main
    ) { _ in
        StartupActions.scheduleWakeMute(reason: "system-wake")
    }
    notificationObservers.append(wakeObserver)

    Log.info("mute-on-startup-agent is running")
    RunLoop.main.run()
}
