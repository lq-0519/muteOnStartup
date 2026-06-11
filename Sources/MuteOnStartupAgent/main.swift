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
        notification.informativeText = "已静音 MacBook Pro 扬声器。"
        center.deliver(notification)
    }
}

private enum CoreAudioMuter {
    private static let globalScope = AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal)
    private static let outputScope = AudioObjectPropertyScope(kAudioDevicePropertyScopeOutput)
    private static let mainElement = AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
    private static let elementsToTry = [mainElement] + (1...8).map(AudioObjectPropertyElement.init)
    private static let builtInTransportType = UInt32(kAudioDeviceTransportTypeBuiltIn)
    private static let silenceThreshold: Float32 = 0.0001

    enum Status {
        case muted
        case alreadySilent
        case notFound
        case failed
    }

    struct Result {
        let status: Status
        let details: [String]
    }

    private struct OutputDevice {
        let id: AudioObjectID
        let name: String
        let uid: String
        let transportType: UInt32?
    }

    private struct DeviceMuteResult {
        let changed: Bool
        let details: [String]
    }

    private struct OutputState {
        let isMuted: Bool?
        let maxVolume: Float32?
        let readableVolumes: [(element: AudioObjectPropertyElement, value: Float32)]
        let readableMutes: [(element: AudioObjectPropertyElement, value: UInt32)]

        var needsMute: Bool {
            if isMuted == true {
                return false
            }

            guard let maxVolume else {
                return true
            }

            return maxVolume > CoreAudioMuter.silenceThreshold
        }

        var summary: String {
            let muteDescription = isMuted.map { String($0) } ?? "unknown"
            let volumeDescription = maxVolume.map(CoreAudioMuter.formatVolume) ?? "unknown"
            let volumeElements = readableVolumes
                .map { "volume element \($0.element)=\(CoreAudioMuter.formatVolume($0.value))" }
                .joined(separator: ", ")
            let muteElements = readableMutes
                .map { "mute element \($0.element)=\($0.value)" }
                .joined(separator: ", ")
            let readableDescription = [
                volumeElements.isEmpty ? nil : volumeElements,
                muteElements.isEmpty ? nil : muteElements
            ]
                .compactMap { $0 }
                .joined(separator: ", ")

            if readableDescription.isEmpty {
                return "current muted=\(muteDescription), maxVolume=\(volumeDescription)"
            }

            return "current muted=\(muteDescription), maxVolume=\(volumeDescription), \(readableDescription)"
        }
    }

    static func muteBuiltInSpeakers() -> Result {
        var details: [String] = []
        var changed = false
        var attemptedMute = false
        let outputDevices = readOutputDevices()
        let targetDevices = outputDevices.filter(isBuiltInSpeaker)

        for device in targetDevices {
            let state = readOutputState(device.id)
            if !state.needsMute {
                details.append("\(device.name) [id=\(device.id), uid=\(device.uid)], already silent, \(state.summary)")
                continue
            }

            attemptedMute = true
            let deviceResult = muteDevice(device.id)
            changed = changed || deviceResult.changed
            details.append("\(device.name) [id=\(device.id), uid=\(device.uid)], \(state.summary), \(deviceResult.details.joined(separator: ", "))")
        }

        if targetDevices.isEmpty {
            let deviceSummary = outputDevices
                .map { "\($0.name) [id=\($0.id), uid=\($0.uid), transport=\($0.transportType.map(String.init) ?? "unknown")]" }
                .joined(separator: "; ")
            details.append("no built-in MacBook speaker found; outputs=\(deviceSummary)")
            return Result(status: .notFound, details: details)
        }

        if changed {
            return Result(status: .muted, details: details)
        }

        return Result(status: attemptedMute ? .failed : .alreadySilent, details: details)
    }

    private static func readOutputDevices() -> [OutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioHardwarePropertyDevices),
            mScope: globalScope,
            mElement: mainElement
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr, dataSize > 0 else {
            Log.error("failed to read CoreAudio device list size: OSStatus \(status)")
            return []
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )
        if status != noErr {
            Log.error("failed to read CoreAudio device list: OSStatus \(status)")
            return []
        }

        return deviceIDs.compactMap { deviceID in
            guard deviceID != AudioObjectID(kAudioObjectUnknown), isOutputDevice(deviceID) else {
                return nil
            }

            return OutputDevice(
                id: deviceID,
                name: readStringProperty(
                    selector: AudioObjectPropertySelector(kAudioObjectPropertyName),
                    deviceID: deviceID
                ) ?? "unknown",
                uid: readStringProperty(
                    selector: AudioObjectPropertySelector(kAudioDevicePropertyDeviceUID),
                    deviceID: deviceID
                ) ?? "unknown",
                transportType: readUInt32Property(
                    selector: AudioObjectPropertySelector(kAudioDevicePropertyTransportType),
                    deviceID: deviceID,
                    scope: globalScope,
                    element: mainElement
                )
            )
        }
    }

    private static func isOutputDevice(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioDevicePropertyStreamConfiguration),
            mScope: outputScope,
            mElement: mainElement
        )

        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard sizeStatus == noErr, dataSize > 0 else {
            return false
        }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer {
            rawPointer.deallocate()
        }

        let dataStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, rawPointer)
        guard dataStatus == noErr else {
            return false
        }

        let bufferListPointer = rawPointer.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private static func isBuiltInSpeaker(_ device: OutputDevice) -> Bool {
        let lowercasedName = device.name.lowercased()
        let lowercasedUID = device.uid.lowercased()
        let looksLikeSpeakerName = lowercasedName.contains("扬声器")
            || lowercasedName.contains("speaker")
        let looksLikeMacBookSpeakerName = lowercasedName.contains("macbook")
            || lowercasedName.contains("built-in")
            || lowercasedName.contains("internal")
            || lowercasedName.contains("内置")
        let looksLikeBuiltInSpeakerUID = lowercasedUID.contains("builtinspeaker")
            || lowercasedUID.contains("builtinoutput")
        let isBuiltInTransport = device.transportType == builtInTransportType

        return looksLikeBuiltInSpeakerUID
            || (isBuiltInTransport && looksLikeSpeakerName && looksLikeMacBookSpeakerName)
    }

    private static func readOutputState(_ deviceID: AudioObjectID) -> OutputState {
        let readableVolumes = elementsToTry.compactMap { element -> (element: AudioObjectPropertyElement, value: Float32)? in
            guard let value = readFloat32Property(
                selector: AudioObjectPropertySelector(kAudioDevicePropertyVolumeScalar),
                deviceID: deviceID,
                scope: outputScope,
                element: element
            ) else {
                return nil
            }

            return (element: element, value: value)
        }
        let readableMutes = elementsToTry.compactMap { element -> (element: AudioObjectPropertyElement, value: UInt32)? in
            guard let value = readUInt32Property(
                selector: AudioObjectPropertySelector(kAudioDevicePropertyMute),
                deviceID: deviceID,
                scope: outputScope,
                element: element
            ) else {
                return nil
            }

            return (element: element, value: value)
        }
        let isMuted: Bool?
        if readableMutes.isEmpty {
            isMuted = nil
        } else {
            isMuted = readableMutes.contains { $0.value != 0 }
        }
        let maxVolume = readableVolumes.map { $0.value }.max()

        return OutputState(
            isMuted: isMuted,
            maxVolume: maxVolume,
            readableVolumes: readableVolumes,
            readableMutes: readableMutes
        )
    }

    private static func readStringProperty(
        selector: AudioObjectPropertySelector,
        deviceID: AudioObjectID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: globalScope,
            mElement: mainElement
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }

        guard status == noErr else {
            return nil
        }

        return value as String
    }

    private static func readUInt32Property(
        selector: AudioObjectPropertySelector,
        deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return nil
        }

        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr else {
            return nil
        }

        return value
    }

    private static func readFloat32Property(
        selector: AudioObjectPropertySelector,
        deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return nil
        }

        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr else {
            return nil
        }

        return value
    }

    private static func formatVolume(_ value: Float32) -> String {
        String(format: "%.3f", Double(value))
    }

    private static func muteDevice(_ deviceID: AudioObjectID) -> DeviceMuteResult {
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

        return DeviceMuteResult(changed: changed, details: details)
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
        let result = CoreAudioMuter.muteBuiltInSpeakers()
        switch result.status {
        case .muted:
            Log.info("muted built-in speaker volume for \(reason): \(result.details.joined(separator: "; "))")
            SystemNotifier.showMutedNotification()
        case .alreadySilent:
            Log.info("skipped built-in speaker mute for \(reason): already silent; \(result.details.joined(separator: "; "))")
        case .notFound, .failed:
            Log.error("did not mute built-in speaker for \(reason): \(result.details.joined(separator: "; "))")
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
    private static let automaticSwitchKey = "AppleInterfaceStyleSwitchesAutomatically" as CFString
    private static let osascriptPath = "/usr/bin/osascript"
    private static let themeChangedNotification = Notification.Name("AppleInterfaceThemeChangedNotification")
    private static let disableDarkModeScript = [
        "tell application \"System Events\"",
        "  tell appearance preferences",
        "    set dark mode to false",
        "  end tell",
        "end tell"
    ]

    static func disableDarkModeDuringMorning(reason: String) {
        guard MorningWindow.contains() else {
            Log.info("skipped light appearance for \(reason): outside 06:30-12:00")
            return
        }

        let systemEventsApplied = disableDarkModeUsingSystemEvents(reason: reason)
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
            CFPreferencesSetValue(
                automaticSwitchKey,
                kCFBooleanFalse,
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
            Log.info("applied light appearance for \(reason): systemEvents=\(systemEventsApplied), previous AppleInterfaceStyle=\(previousDescription)")
        } else {
            Log.error("requested light appearance for \(reason), but CFPreferencesSynchronize returned false")
        }
    }

    private static func disableDarkModeUsingSystemEvents(reason: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: osascriptPath)
        process.arguments = disableDarkModeScript.flatMap { ["-e", $0] }

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Log.error("failed to start System Events appearance script for \(reason): \(error)")
            return false
        }

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Log.error("System Events appearance script exited with \(process.terminationStatus) for \(reason): \(errorMessage ?? "no stderr")")
            return false
        }

        return true
    }
}

private enum StartupActions {
    static func run(reason: String) {
        VolumeMuter.mute(reason: reason)
        AppearanceManager.disableDarkModeDuringMorning(reason: reason)
    }

    static func scheduleWakeActions(reason: String) {
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
      mute-on-startup-agent --once     Mute built-in MacBook speaker once.
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
        StartupActions.scheduleWakeActions(reason: "system-wake")
    }
    notificationObservers.append(wakeObserver)

    Log.info("mute-on-startup-agent is running")
    RunLoop.main.run()
}
