import AppKit
import AVFoundation
import CoreAudio
import Darwin
import MediaPlayer
import OSLog
import ServiceManagement

private enum Product {
    static let name = "Microphone Control"
    static let bundleIdentifier = "app.microphonecontrol"
    static let startupPlistName = "app.microphonecontrol.agent.plist"
    static let managedEnvironmentKey = "MICROPHONE_CONTROL_MANAGED"
}

private let inputEventLogger = Logger(
    subsystem: Product.bundleIdentifier,
    category: "InputEvents"
)

private enum StartupDisposition {
    case run
    case handOffToManagedService
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let inputEngine = AVAudioEngine()
    private let startupService = SMAppService.agent(plistName: Product.startupPlistName)
    private var startupMenuItem: NSMenuItem?
    private var originalVolume: Float32 = 1
    private var originalMuted = false
    private var usesDeviceMute = false
    private var muted = false
    private var usesAirPodsMuteAPI = false
    private var remoteCommandTokens: [Any] = []
    private var inputTapInstalled = false
    private var microphonePermissionGranted = false
    private var instanceLockFileDescriptor: Int32 = -1
    private var approvalTimer: Timer?

    private var isDevelopmentLaunch: Bool {
        CommandLine.arguments.contains("--development")
    }

    private var isManagedLaunch: Bool {
        ProcessInfo.processInfo.environment[Product.managedEnvironmentKey] == "1"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if handleMaintenanceCommandIfNeeded() {
            return
        }

        guard installForCurrentUserIfNeeded() else { return }
        configureMenu()

        if !isDevelopmentLaunch && !isManagedLaunch {
            requestPermissionBeforeStartupRegistration()
            return
        }

        startRuntime(permissionAlreadyGranted: false)
    }

    private func handleMaintenanceCommandIfNeeded() -> Bool {
        let arguments = Set(CommandLine.arguments.dropFirst())
        guard arguments.contains("--unregister-startup") || arguments.contains("--repair-startup") else {
            return false
        }

        do {
            if startupService.status != .notRegistered && startupService.status != .notFound {
                try startupService.unregister()
            }
            if arguments.contains("--repair-startup") {
                try startupService.register()
            }
        } catch {
            inputEventLogger.error("Startup service maintenance failed: \(error.localizedDescription, privacy: .public)")
        }
        NSApp.terminate(nil)
        return true
    }

    private func requestPermissionBeforeStartupRegistration() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    inputEventLogger.error("Microphone permission was not granted during first-run setup")
                    Self.showMicrophonePermissionHelp()
                    return
                }
                self.microphonePermissionGranted = true
                self.completeStartupRegistration()
            }
        }
    }

    private func completeStartupRegistration() {
        switch ensureAutomaticStartup() {
        case .run:
            startRuntime(permissionAlreadyGranted: true)
        case .handOffToManagedService:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.terminate(nil)
            }
        }
    }

    private func startRuntime(permissionAlreadyGranted: Bool) {
        guard acquireInstanceLock() else {
            inputEventLogger.info("Another Microphone Control process is already active")
            NSApp.terminate(nil)
            return
        }

        configureRemoteCommandTelemetry()
        configureAirPodsMuteControl()
        configureInputSessionRetention(permissionAlreadyGranted: permissionAlreadyGranted)
        refreshStatus()
        inputEventLogger.info("Microphone Control launched; input muted: \(AVAudioApplication.shared.isInputMuted)")
    }

    private func installForCurrentUserIfNeeded() -> Bool {
        guard !isDevelopmentLaunch else { return true }

        let fileManager = FileManager.default
        let applicationsDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        let installedApplication = applicationsDirectory
            .appendingPathComponent("\(Product.name).app", isDirectory: true)
        let currentApplication = Bundle.main.bundleURL.standardizedFileURL

        guard currentApplication != installedApplication.standardizedFileURL else { return true }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Install \(Product.name)?"
        alert.informativeText = "This installs Microphone Control for your user account and starts it automatically whenever you sign in. Microphone audio is discarded immediately and is never stored or transmitted."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            NSApp.terminate(nil)
            return false
        }

        do {
            try fileManager.createDirectory(at: applicationsDirectory, withIntermediateDirectories: true)
            try replaceInstalledApplication(
                source: currentApplication,
                destination: installedApplication,
                fileManager: fileManager
            )

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: installedApplication, configuration: configuration) { _, error in
                if let error {
                    Self.showError(title: "Installation completed", message: "Open Microphone Control from your Applications folder. \(error.localizedDescription)")
                }
                NSApp.terminate(nil)
            }
        } catch {
            Self.showError(title: "Installation failed", message: error.localizedDescription)
            NSApp.terminate(nil)
        }
        return false
    }

    private func replaceInstalledApplication(
        source: URL,
        destination: URL,
        fileManager: FileManager
    ) throws {
        let stagingURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".microphone-control-install-\(UUID().uuidString).app")
        let backupURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".microphone-control-backup-\(UUID().uuidString).app")

        try fileManager.copyItem(at: source, to: stagingURL)
        var movedExistingApplication = false
        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.moveItem(at: destination, to: backupURL)
                movedExistingApplication = true
            }
            try fileManager.moveItem(at: stagingURL, to: destination)
            if movedExistingApplication {
                try? fileManager.removeItem(at: backupURL)
            }
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            if movedExistingApplication, !fileManager.fileExists(atPath: destination.path) {
                try? fileManager.moveItem(at: backupURL, to: destination)
            }
            throw error
        }
    }

    private func ensureAutomaticStartup() -> StartupDisposition {
        switch startupService.status {
        case .enabled:
            refreshStartupMenuItem()
            return isManagedLaunch ? .run : .handOffToManagedService
        case .requiresApproval:
            refreshStartupMenuItem()
            showStartupApproval()
            monitorStartupApproval()
            return .run
        case .notRegistered, .notFound:
            do {
                try startupService.register()
                refreshStartupMenuItem()
                if startupService.status == .requiresApproval {
                    showStartupApproval()
                    monitorStartupApproval()
                    return .run
                }
                return isManagedLaunch ? .run : .handOffToManagedService
            } catch {
                inputEventLogger.error("Automatic startup registration failed: \(error.localizedDescription, privacy: .public)")
                Self.showError(
                    title: "Automatic startup needs attention",
                    message: "Microphone Control is running now, but could not enable automatic startup. \(error.localizedDescription)"
                )
                return .run
            }
        @unknown default:
            return .run
        }
    }

    private func monitorStartupApproval() {
        guard !isManagedLaunch else { return }
        approvalTimer?.invalidate()
        approvalTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            guard self.startupService.status == .enabled else { return }
            timer.invalidate()
            self.approvalTimer = nil
            self.refreshStartupMenuItem()
            NSApp.terminate(nil)
        }
    }

    private func showStartupApproval() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Allow automatic startup"
        alert.informativeText = "Allow Microphone Control in System Settings under General > Login Items so it is ready whenever you sign in or open a calling app."
        alert.addButton(withTitle: "Open Login Items")
        alert.addButton(withTitle: "Continue for Now")
        if alert.runModal() == .alertFirstButtonReturn {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private func acquireInstanceLock() -> Bool {
        let lockDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Product.bundleIdentifier, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        } catch {
            inputEventLogger.error("Could not create the process-lock directory: \(error.localizedDescription, privacy: .public)")
            return false
        }

        let lockPath = lockDirectory.appendingPathComponent("instance.lock").path
        let descriptor = Darwin.open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return false }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            return false
        }
        instanceLockFileDescriptor = descriptor
        return true
    }

    private func configureInputSessionRetention(permissionAlreadyGranted: Bool) {
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: inputEngine,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.microphonePermissionGranted else { return }
            inputEventLogger.info("Audio configuration changed; refreshing the input session")
            self.startRetainedInputSession(reason: "configuration-change")
        }

        if permissionAlreadyGranted {
            microphonePermissionGranted = true
            startRetainedInputSession(reason: "permission-granted")
            return
        }

        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                self.microphonePermissionGranted = granted
                inputEventLogger.info("Microphone permission resolved; granted: \(granted)")
                guard granted else {
                    inputEventLogger.error("The input session cannot start without microphone permission")
                    if !self.isManagedLaunch {
                        Self.showMicrophonePermissionHelp()
                    }
                    return
                }
                self.startRetainedInputSession(reason: "permission-granted")
            }
        }
    }

    private func startRetainedInputSession(reason: String) {
        if inputEngine.isRunning {
            inputEventLogger.info("Input session already active; reason: \(reason, privacy: .public)")
            return
        }

        let input = inputEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            inputEventLogger.error("The default microphone returned an unusable audio format")
            return
        }

        if inputTapInstalled {
            input.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { _, _ in
            // Audio buffers are intentionally discarded immediately.
        }
        inputTapInstalled = true

        do {
            inputEngine.prepare()
            try inputEngine.start()
            inputEventLogger.info(
                "Input session started; reason: \(reason, privacy: .public); sample rate: \(format.sampleRate); channels: \(format.channelCount)"
            )
        } catch {
            inputEventLogger.error("Input session failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func configureRemoteCommandTelemetry() {
        let centre = MPRemoteCommandCenter.shared()
        registerRemoteCommand(centre.playCommand, name: "play")
        registerRemoteCommand(centre.pauseCommand, name: "pause")
        registerRemoteCommand(centre.togglePlayPauseCommand, name: "togglePlayPause")
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: Product.name,
            MPNowPlayingInfoPropertyPlaybackRate: 0.0,
        ]
        inputEventLogger.info("Remote-command telemetry registered")
    }

    private func registerRemoteCommand(_ command: MPRemoteCommand, name: String) {
        command.isEnabled = true
        let token = command.addTarget { event in
            inputEventLogger.info("Remote command received: \(name, privacy: .public); event type: \(String(describing: type(of: event)), privacy: .public)")
            return .success
        }
        remoteCommandTokens.append(token)
    }

    private func configureMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Toggle Microphone", action: #selector(toggleMicrophone), keyEquivalent: "m"))
        let automaticStartupItem = NSMenuItem(title: "Start Automatically", action: #selector(toggleAutomaticStartup), keyEquivalent: "")
        automaticStartupItem.target = self
        startupMenuItem = automaticStartupItem
        menu.addItem(automaticStartupItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Microphone Control", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggleMicrophone)
        refreshStartupMenuItem()
    }

    private func refreshStartupMenuItem() {
        switch startupService.status {
        case .enabled:
            startupMenuItem?.state = .on
        case .requiresApproval:
            startupMenuItem?.state = .mixed
        default:
            startupMenuItem?.state = .off
        }
    }

    @objc private func toggleAutomaticStartup() {
        do {
            switch startupService.status {
            case .enabled, .requiresApproval:
                try startupService.unregister()
            case .notRegistered, .notFound:
                try startupService.register()
                if startupService.status == .requiresApproval {
                    showStartupApproval()
                }
            @unknown default:
                break
            }
            refreshStartupMenuItem()
        } catch {
            Self.showError(title: "Could not update automatic startup", message: error.localizedDescription)
        }
    }

    private func configureAirPodsMuteControl() {
        do {
            NotificationCenter.default.addObserver(
                forName: AVAudioApplication.inputMuteStateChangeNotification,
                object: AVAudioApplication.shared,
                queue: .main
            ) { [weak self] notification in
                guard let self else { return }
                let state = notification.userInfo?[AVAudioApplication.muteStateKey] as? Bool
                    ?? AVAudioApplication.shared.isInputMuted
                inputEventLogger.info("Microphone mute state changed; muted: \(state)")
                self.muted = state
                self.refreshStatus()
            }
            try AVAudioApplication.shared.setInputMuteStateChangeHandler { [weak self] shouldMute in
                guard let self else { return false }
                inputEventLogger.info("Microphone mute requested; muted: \(shouldMute)")
                let applied = self.applyGlobalMicrophoneMute(shouldMute)
                inputEventLogger.info("Microphone mute request completed; success: \(applied)")
                return applied
            }
            usesAirPodsMuteAPI = true
            inputEventLogger.info("Microphone mute handler registered")
        } catch {
            inputEventLogger.error("Microphone mute handler registration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @objc private func toggleMicrophone() {
        inputEventLogger.info("Menu microphone toggle requested")
        if usesAirPodsMuteAPI {
            do {
                try AVAudioApplication.shared.setInputMuted(!AVAudioApplication.shared.isInputMuted)
                return
            } catch {
                inputEventLogger.error("Microphone state change failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        _ = applyGlobalMicrophoneMute(!muted)
        refreshStatus()
    }

    private func applyGlobalMicrophoneMute(_ shouldMute: Bool) -> Bool {
        guard let deviceID = defaultInputDevice() else {
            inputEventLogger.error("No default microphone was available")
            return false
        }
        if !shouldMute {
            if usesDeviceMute {
                guard setInputMuted(originalMuted, for: deviceID) else { return false }
            } else if !setInputVolume(originalVolume, for: deviceID) {
                return false
            }
        } else {
            if let isMuted = inputMuted(for: deviceID) {
                originalMuted = isMuted
                usesDeviceMute = true
                guard setInputMuted(true, for: deviceID) else { return false }
            } else {
                originalVolume = max(inputVolume(for: deviceID), 0.01)
                usesDeviceMute = false
                guard setInputVolume(0, for: deviceID) else { return false }
            }
        }
        muted = shouldMute
        return true
    }

    private func refreshStatus() {
        let label = muted ? "Mic: muted" : "Mic: live"
        statusItem.button?.title = label
        inputEventLogger.info("Status updated: \(label, privacy: .public)")
    }

    @objc private func quit() {
        if startupService.status == .enabled || startupService.status == .requiresApproval {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Disable automatic startup and quit?"
            alert.informativeText = "Microphone Control is kept available automatically. Disabling automatic startup will also prevent it from opening after you sign in."
            alert.addButton(withTitle: "Disable and Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do {
                try startupService.unregister()
            } catch {
                Self.showError(title: "Could not disable automatic startup", message: error.localizedDescription)
                return
            }
        }
        shutDownAudio()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        shutDownAudio()
    }

    private func shutDownAudio() {
        approvalTimer?.invalidate()
        approvalTimer = nil
        if inputTapInstalled {
            inputEngine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        inputEngine.stop()
        if instanceLockFileDescriptor >= 0 {
            flock(instanceLockFileDescriptor, LOCK_UN)
            Darwin.close(instanceLockFileDescriptor)
            instanceLockFileDescriptor = -1
        }
    }

    private static func showMicrophonePermissionHelp() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Microphone access is required"
        alert.informativeText = "Allow Microphone Control in System Settings under Privacy & Security > Microphone, then reopen the app. Audio is discarded immediately and is never stored or transmitted."
        alert.addButton(withTitle: "Open Microphone Settings")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn,
           let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(settingsURL)
        }
    }

    private static func showError(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private func defaultInputDevice() -> AudioDeviceID? {
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
}

private func inputVolume(for deviceID: AudioDeviceID) -> Float32 {
    var value: Float32 = 1
    var size = UInt32(MemoryLayout<Float32>.size)
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr ? value : 1
}

private func inputMuted(for deviceID: AudioDeviceID) -> Bool? {
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value != 0
}

private func setInputMuted(_ value: Bool, for deviceID: AudioDeviceID) -> Bool {
    var mutableValue: UInt32 = value ? 1 : 0
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    return AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &mutableValue) == noErr
}

private func setInputVolume(_ value: Float32, for deviceID: AudioDeviceID) -> Bool {
    var mutableValue = value
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    return AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &mutableValue) == noErr
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
