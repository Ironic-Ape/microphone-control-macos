import AppKit

private enum InstallerProduct {
    static let installerName = "Install Microphone Control"
    static let applicationName = "Microphone Control"
    static let executableName = "MicrophoneControl"
}

final class InstallerDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Install Microphone Control?"
        alert.informativeText = "This installs Microphone Control for your user account and keeps it ready whenever you sign in or open a calling app. Microphone audio is discarded immediately and is never stored or transmitted."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            NSApp.terminate(nil)
            return
        }

        do {
            let installedApplication = try installApplication()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: installedApplication, configuration: configuration) { _, error in
                if let error {
                    Self.showResult(
                        title: "Installation completed",
                        message: "Open Microphone Control from your user Applications folder. \(error.localizedDescription)"
                    )
                }
                NSApp.terminate(nil)
            }
        } catch {
            Self.showResult(title: "Installation failed", message: error.localizedDescription)
            NSApp.terminate(nil)
        }
    }

    private func installApplication() throws -> URL {
        let fileManager = FileManager.default
        guard let resourcesDirectory = Bundle.main.resourceURL else {
            throw InstallerError.missingPayload
        }
        let payload = resourcesDirectory
            .appendingPathComponent("Payload", isDirectory: true)
            .appendingPathComponent("\(InstallerProduct.applicationName).app", isDirectory: true)
        guard fileManager.fileExists(atPath: payload.path) else {
            throw InstallerError.missingPayload
        }

        let applicationsDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        let destination = applicationsDirectory
            .appendingPathComponent("\(InstallerProduct.applicationName).app", isDirectory: true)
        try fileManager.createDirectory(at: applicationsDirectory, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: destination.path) {
            try unregisterExistingStartupService(in: destination)
        }

        let stagingURL = applicationsDirectory
            .appendingPathComponent(".microphone-control-install-\(UUID().uuidString).app")
        let backupURL = applicationsDirectory
            .appendingPathComponent(".microphone-control-backup-\(UUID().uuidString).app")

        try fileManager.copyItem(at: payload, to: stagingURL)
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

        return destination
    }

    private func unregisterExistingStartupService(in application: URL) throws {
        let executable = application
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(InstallerProduct.executableName)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["--unregister-startup"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallerError.couldNotDisablePreviousStartup
        }

        let runningHelpers = NSRunningApplication.runningApplications(withBundleIdentifier: "app.microphonecontrol")
        for application in runningHelpers {
            application.terminate()
        }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline,
              NSRunningApplication.runningApplications(withBundleIdentifier: "app.microphonecontrol").contains(where: { !$0.isTerminated }) {
            Thread.sleep(forTimeInterval: 0.1)
        }

        for application in NSRunningApplication.runningApplications(withBundleIdentifier: "app.microphonecontrol") where !application.isTerminated {
            application.forceTerminate()
        }
    }

    private static func showResult(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private enum InstallerError: LocalizedError {
    case missingPayload
    case couldNotDisablePreviousStartup

    var errorDescription: String? {
        switch self {
        case .missingPayload:
            return "The installer does not contain the Microphone Control application. Download a new copy and try again."
        case .couldNotDisablePreviousStartup:
            return "The previous automatic-start service could not be disabled safely. Quit Microphone Control and try again."
        }
    }
}

let app = NSApplication.shared
let delegate = InstallerDelegate()
app.delegate = delegate
app.run()
