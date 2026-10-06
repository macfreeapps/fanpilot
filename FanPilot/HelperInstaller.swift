import Foundation
import ServiceManagement
import CryptoKit
import Security

@MainActor enum HelperInstaller {
    private static let daemonLabel = "com.fanpilot.helper"
    private static let helperDestination = "/Library/PrivilegedHelperTools/com.fanpilot.helper"
    private static let plistDestination = "/Library/LaunchDaemons/com.fanpilot.helper.plist"

    static var status: String {
        let serviceStatus = isDeveloperIDSigned ? SMAppService.daemon(plistName: "com.fanpilot.helper.plist").status : .notRegistered
        if serviceStatus == .enabled || legacyDaemonIsLoaded { return "Installed" }
        if serviceStatus == .requiresApproval { return "Approval required in System Settings" }
        return "Not installed"
    }

    static func install() async throws {
        // SMAppService daemons require a Developer ID signature. Personal Apple Development builds
        // use the administrator-prompt LaunchDaemon install, which also refreshes a running helper.
        guard isDeveloperIDSigned else {
            try await installLegacyDaemon()
            return
        }
        let service = SMAppService.daemon(plistName: "com.fanpilot.helper.plist")
        // An explicit Install / Update action must refresh the executable already
        // registered from this bundle, not leave launchd running its old image.
        if service.status == .enabled { try await service.unregister() }
        try service.register()
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    private static var isDeveloperIDSigned: Bool {
        codeSignatureIsValid(Bundle.main.bundleURL, requirement: "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13]")
    }

    static func uninstall() async throws {
        let service = SMAppService.daemon(plistName: "com.fanpilot.helper.plist")
        if isDeveloperIDSigned, service.status == .enabled || service.status == .requiresApproval {
            try await service.unregister()
            return
        }
        // Clear any stray Service Management registration from earlier builds; ignore failures.
        if service.status != .notRegistered, service.status != .notFound { try? await service.unregister() }
        guard legacyFilesExist || legacyDaemonIsLoaded else { return }
        let script = #"""
on run argv
set uninstallCommand to "/bin/launchctl bootout system " & quoted form of "/Library/LaunchDaemons/com.fanpilot.helper.plist" & " 2>/dev/null || true"
set uninstallCommand to uninstallCommand & " && /bin/rm -f " & quoted form of "/Library/PrivilegedHelperTools/com.fanpilot.helper" & " " & quoted form of "/Library/LaunchDaemons/com.fanpilot.helper.plist"
do shell script uninstallCommand with administrator privileges
end run
"""#
        try await runAdminScript(script, arguments: [])
    }

    static func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }

    static var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    private static func installLegacyDaemon() async throws {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        let bundlePath = bundleURL.path
        guard bundlePath.hasPrefix("/Applications/") else {
            throw NSError(domain: "FanPilot", code: 10, userInfo: [NSLocalizedDescriptionKey: "Move FanPilot to /Applications before installing the privileged helper."])
        }
        let helper = bundleURL.appendingPathComponent("Contents/MacOS/FanPilotHelper").path
        let plist = bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/com.fanpilot.helper.legacy.plist").path
        guard FileManager.default.isExecutableFile(atPath: helper), FileManager.default.fileExists(atPath: plist) else {
            throw NSError(domain: "FanPilot", code: 11, userInfo: [NSLocalizedDescriptionKey: "The helper or LaunchDaemon plist is missing from the app bundle."])
        }
        guard codeSignatureIsValid(bundleURL, requirement: "identifier \"com.fanpilot.app\" and anchor apple generic and certificate leaf[subject.OU] = \"YUVK5PXJXH\""),
              codeSignatureIsValid(URL(fileURLWithPath: helper), requirement: "identifier \"FanPilotHelper\" and anchor apple generic and certificate leaf[subject.OU] = \"YUVK5PXJXH\"") else {
            throw NSError(domain: "FanPilot", code: 12, userInfo: [NSLocalizedDescriptionKey: "FanPilot or its helper failed Apple code-signature verification."])
        }
        let helperHash = try sha256(URL(fileURLWithPath: helper))
        let plistHash = try sha256(URL(fileURLWithPath: plist))
        let script = #"""
on run argv
set sourceHelper to item 1 of argv
set expectedHelperHash to item 2 of argv
set sourcePlist to item 3 of argv
set expectedPlistHash to item 4 of argv
set installCommand to "/usr/bin/pkill -TERM -x FanPilotHelper 2>/dev/null || true"
set installCommand to installCommand & " && /bin/sleep 2"
set installCommand to installCommand & " && /bin/launchctl bootout system " & quoted form of "/Library/LaunchDaemons/com.fanpilot.helper.plist" & " 2>/dev/null || true"
set installCommand to installCommand & " && /usr/bin/install -d -o root -g wheel -m 755 " & quoted form of "/Library/PrivilegedHelperTools"
set installCommand to installCommand & " && /bin/cp " & quoted form of sourceHelper & " " & quoted form of "/Library/PrivilegedHelperTools/com.fanpilot.helper"
set installCommand to installCommand & " && /usr/bin/shasum -a 256 " & quoted form of "/Library/PrivilegedHelperTools/com.fanpilot.helper" & " | /usr/bin/grep -q \"^" & expectedHelperHash & " \""
set installCommand to installCommand & " && /bin/cp " & quoted form of sourcePlist & " " & quoted form of "/Library/LaunchDaemons/com.fanpilot.helper.plist"
set installCommand to installCommand & " && /usr/bin/shasum -a 256 " & quoted form of "/Library/LaunchDaemons/com.fanpilot.helper.plist" & " | /usr/bin/grep -q \"^" & expectedPlistHash & " \""
set installCommand to installCommand & " && /usr/sbin/chown root:wheel " & quoted form of "/Library/PrivilegedHelperTools/com.fanpilot.helper" & " " & quoted form of "/Library/LaunchDaemons/com.fanpilot.helper.plist"
set installCommand to installCommand & " && /bin/chmod 755 " & quoted form of "/Library/PrivilegedHelperTools/com.fanpilot.helper" & " && /bin/chmod 644 " & quoted form of "/Library/LaunchDaemons/com.fanpilot.helper.plist"
set installCommand to installCommand & " && /usr/bin/codesign --verify --strict -R=" & quoted form of "identifier \"FanPilotHelper\" and anchor apple generic and certificate leaf[subject.OU] = \"YUVK5PXJXH\"" & " " & quoted form of "/Library/PrivilegedHelperTools/com.fanpilot.helper"
set installCommand to installCommand & " && /usr/bin/plutil -lint " & quoted form of "/Library/LaunchDaemons/com.fanpilot.helper.plist" & " >/dev/null"
set installCommand to installCommand & " && /bin/launchctl bootstrap system " & quoted form of "/Library/LaunchDaemons/com.fanpilot.helper.plist"
do shell script installCommand with administrator privileges
end run
"""#
        try await runAdminScript(script, arguments: [helper, helperHash, plist, plistHash])
    }

    private static func codeSignatureIsValid(_ url: URL, requirement: String) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess,
              let code else { return false }
        var codeRequirement: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, SecCSFlags(), &codeRequirement) == errSecSuccess,
              let codeRequirement else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(), codeRequirement) == errSecSuccess
    }

    private static func sha256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static var legacyFilesExist: Bool {
        FileManager.default.fileExists(atPath: helperDestination) && FileManager.default.fileExists(atPath: plistDestination)
    }

    private static var legacyDaemonIsLoaded: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "system/\(daemonLabel)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 }
        catch { return false }
    }

    private static func runAdminScript(_ script: String, arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script] + arguments
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { process in
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                guard process.terminationStatus == 0 else {
                    let detail = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: NSError(domain: "FanPilot", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: detail.isEmpty ? "Administrator installation failed or was cancelled." : detail]))
                    return
                }
                continuation.resume()
            }
            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }
    }
}
