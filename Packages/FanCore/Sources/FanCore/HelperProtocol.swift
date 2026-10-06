import Foundation

@objc public protocol FanHelperProtocol {
    func version(reply: @escaping @Sendable (String) -> Void)
    func setMode(_ raw: Int, dailyConfig: Data, reply: @escaping @Sendable (Bool, String?) -> Void)
    func snapshot(reply: @escaping @Sendable (Data) -> Void)
    func heartbeat()
    func restoreSystemControl(reply: @escaping @Sendable (Bool) -> Void)
    func prepareForUninstall(reply: @escaping @Sendable (Bool, String?) -> Void)
}
