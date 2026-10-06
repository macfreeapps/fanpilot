import Foundation
import Observation
import FanCore

@MainActor @Observable final class HelperClient {
    var installed = false
    /// The mode the user selected; persisted so "Remember last mode" can reapply it at launch.
    var mode: FanMode = .normal {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "lastMode") }
    }
    private var didApplyRememberedMode = false
    /// True while the one-time administrator approval for the helper is pending or running.
    var isInstalling = false
    var error: String?
    var snapshot = HelperState()
    /// True while a mode change is in flight; on M3/M4 the thermal-manager unlock takes 3–6 s.
    var changingMode: Bool { pendingModeChanges > 0 }
    private var pendingModeChanges = 0
    private var connection: NSXPCConnection?
    private var connectionID: UUID?
    private var beat: Task<Void, Never>?
    init() {
        connect()
        beat = Task {
            while !Task.isCancelled {
                if connection == nil { connect() }
                else { heartbeat(); refresh() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    private func connect() {
        guard connection == nil else { return }
        let connectionID = UUID()
        self.connectionID = connectionID
        let c = NSXPCConnection(machServiceName: "com.fanpilot.helper", options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)
        c.invalidationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, self.connectionID == connectionID else { return }
                self.connection = nil
                self.connectionID = nil
                self.installed = false
            }
        }
        c.interruptionHandler = { [weak self] in
            Task { @MainActor in
                guard let self, self.connectionID == connectionID else { return }
                self.connection?.invalidate()
                self.connection = nil
                self.connectionID = nil
                self.installed = false
            }
        }
        c.resume(); connection = c
        (c.remoteObjectProxy as? FanHelperProtocol)?.version { [weak self] version in
            Task { @MainActor in
                guard let self, self.connectionID == connectionID else { return }
                self.installed = version == "1.0"
                self.error = version == "1.0" ? nil : "FanPilot helper version mismatch"
                if self.installed { self.applyRememberedModeOnce() }
            }
        }
    }
    /// Once per app launch, so a helper restart or recovery stays in Normal as intended.
    private func applyRememberedModeOnce() {
        guard !didApplyRememberedMode else { return }
        didApplyRememberedMode = true
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "rememberMode") == nil || defaults.bool(forKey: "rememberMode"),
              let remembered = FanMode(rawValue: defaults.integer(forKey: "lastMode")), remembered != .normal else { return }
        let config = defaults.data(forKey: "dailyConfig").flatMap { try? JSONDecoder().decode(DailyConfig.self, from: $0) } ?? DailyConfig()
        mode = remembered
        setMode(remembered, config: config)
    }
    /// A user's choice of mode: the only path that sends a mode request besides launch and settings changes.
    func choose(_ newMode: FanMode, config: DailyConfig) {
        mode = newMode
        setMode(newMode, config: config)
    }
    func installHelper() async {
        guard !isInstalling else { return }
        isInstalling = true
        defer { isInstalling = false }
        do { try await HelperInstaller.install(); error = nil; reconnect() }
        catch { self.error = error.localizedDescription }
    }
    /// Returns an error message, or nil on success.
    func uninstallHelper() async -> String? {
        let preparationError: String? = await withCheckedContinuation { continuation in
            prepareForUninstall { continuation.resume(returning: $0) }
        }
        if let preparationError { return preparationError }
        do { try await HelperInstaller.uninstall(); reconnect(); return nil }
        catch { return error.localizedDescription }
    }
    func reconnect() {
        connection?.invalidate()
        connection = nil
        connectionID = nil
        installed = false
        connect()
    }
    func heartbeat() { (connection?.remoteObjectProxy as? FanHelperProtocol)?.heartbeat() }
    func refresh() {
        (connection?.remoteObjectProxy as? FanHelperProtocol)?.snapshot { [weak self] data in
            guard let value = try? JSONDecoder().decode(HelperState.self, from: data) else { return }
            Task { @MainActor in
                guard let self else { return }
                self.snapshot = value
                // Show what the helper is actually doing: after a helper restart, crash recovery,
                // or a refused request (another fan tool in control) the selection must not claim
                // a mode that is not active. Skip while a change is in flight.
                if self.pendingModeChanges == 0, self.mode != value.mode { self.mode = value.mode }
            }
        }
    }
    func setMode(_ mode: FanMode, config: DailyConfig) {
        guard let connection, let data = try? JSONEncoder().encode(config.validated()),
              let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] e in
                  Task { @MainActor in self?.finishModeChange(error: e.localizedDescription) }
              }) as? FanHelperProtocol else { error = "FanPilot helper is not installed"; return }
        pendingModeChanges += 1
        proxy.setMode(mode.rawValue, dailyConfig: data) { [weak self] ok, message in
            Task { @MainActor in self?.finishModeChange(error: ok ? nil : (message ?? "Could not change fan mode")) }
        }
    }
    private func finishModeChange(error message: String?) {
        pendingModeChanges = max(0, pendingModeChanges - 1)
        error = message
    }
    func restore(completion: @MainActor @escaping @Sendable () -> Void = {}) {
        guard let proxy = connection?.remoteObjectProxy as? FanHelperProtocol else { completion(); return }
        proxy.restoreSystemControl { [weak self] ok in Task { @MainActor in
            self?.error = ok ? nil : "Could not restore system fan control"
            completion()
        } }
    }
    func prepareForUninstall(completion: @MainActor @escaping @Sendable (String?) -> Void) {
        guard let proxy = connection?.remoteObjectProxy as? FanHelperProtocol else { completion("FanPilot helper is not connected"); return }
        proxy.prepareForUninstall { ok, message in Task { @MainActor in
            if !ok { self.error = message ?? "Could not restore system fan control" }
            completion(ok ? nil : (message ?? "Could not restore system fan control"))
        } }
    }
}
