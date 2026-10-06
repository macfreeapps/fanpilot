import Foundation

public final class FakeSMC: SMCDevice, @unchecked Sendable {
    private struct Entry { var info: SMCKeyInfo; var bytes: [UInt8] }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var orderedKeys: [String] = []
    private var failures: [String: (code: UInt8, remaining: Int)] = [:]
    private var automaticModeValue: Double = 0
    private var delayedManualAcknowledgements = 0
    private var delayedTargetAcknowledgements = 0
    private var targetUpdatesWaitingForRead: [String: (bytes: [UInt8], remainingReads: Int)] = [:]

    public init(fans: Int = 2, modeKeyLowercase: Bool = false, hasFtst: Bool = true) {
        put("FNum", number: Double(fans), type: "ui8 ", size: 1)
        if hasFtst { put("Ftst", number: 0, type: "ui8 ", size: 1) }
        for index in 0..<fans {
            let mode = "F\(index)\(modeKeyLowercase ? "m" : "M")d"
            put("F\(index)Ac", number: 0, type: "flt ", size: 4)
            put("F\(index)Tg", number: 1200, type: "flt ", size: 4)
            put("F\(index)Mn", number: 1200, type: "flt ", size: 4)
            put("F\(index)Mx", number: 6000, type: "flt ", size: 4)
            put(mode, number: 0, type: "ui8 ", size: 1)
        }
        put("Tp01", number: 45, type: "flt ", size: 4)
        lock.lock(); let count = orderedKeys.count + 1; lock.unlock()
        put("#KEY", number: Double(count), type: "ui32", size: 4)
    }

    public func seed(_ key: String, number: Double, type: String, size: Int) {
        put(key, number: number, type: type, size: size)
        lock.lock(); let count = orderedKeys.count; lock.unlock()
        put("#KEY", number: Double(count), type: "ui32", size: 4)
    }
    public func setAutomaticModeValue(_ value: Double) { lock.lock(); automaticModeValue = value; lock.unlock() }
    public func delayManualAcknowledgements(_ count: Int) { lock.lock(); delayedManualAcknowledgements = max(0, count); lock.unlock() }
    public func delayTargetAcknowledgements(_ count: Int) { lock.lock(); delayedTargetAcknowledgements = max(0, count); lock.unlock() }
    public func failNextWrites(to key: String, code: UInt8, count: Int) { lock.lock(); failures[key] = (code, count); lock.unlock() }
    public func keyInfo(_ key: String) throws -> SMCKeyInfo {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[key] else { throw SMCError.notFound }
        return entry.info
    }
    public func read(_ key: String) throws -> SMCValue {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[key] else { throw SMCError.notFound }
        if var pending = targetUpdatesWaitingForRead[key] {
            if pending.remainingReads > 0 {
                pending.remainingReads -= 1
                targetUpdatesWaitingForRead[key] = pending
                if pending.remainingReads > 0 { return SMCValue(info: entry.info, bytes: entry.bytes) }
            }
            var updated = entry; updated.bytes = pending.bytes; entries[key] = updated
            targetUpdatesWaitingForRead.removeValue(forKey: key)
            return SMCValue(info: updated.info, bytes: updated.bytes)
        }
        return SMCValue(info: entry.info, bytes: entry.bytes)
    }
    public func write(_ key: String, bytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[key] else { throw SMCError.notFound }
        if let failure = failures[key], failure.remaining > 0 {
            failures[key] = (failure.code, failure.remaining - 1)
            throw SMCError.result(failure.code)
        }
        guard bytes.count == entry.info.size else { throw SMCError.sizeMismatch }
        if key.range(of: #"^F[0-9]+[Mm]d$"#, options: .regularExpression) != nil,
           let value = try? SMCCodec.number(SMCValue(info: entry.info, bytes: bytes)), value == 0,
           let autoBytes = try? SMCCodec.bytes(automaticModeValue, type: entry.info.type, size: entry.info.size) {
            entry.bytes = autoBytes; entries[key] = entry; return
        }
        if key.range(of: #"^F[0-9]+[Mm]d$"#, options: .regularExpression) != nil,
           let value = try? SMCCodec.number(SMCValue(info: entry.info, bytes: bytes)), value == 1,
           let unlock = entries["Ftst"], (try? SMCCodec.number(SMCValue(info: unlock.info, bytes: unlock.bytes))) == 1,
           delayedManualAcknowledgements > 0 {
            delayedManualAcknowledgements -= 1; return
        }
        if key.range(of: #"^F[0-9]+Tg$"#, options: .regularExpression) != nil,
           delayedTargetAcknowledgements > 0 {
            targetUpdatesWaitingForRead[key] = (bytes, delayedTargetAcknowledgements)
            delayedTargetAcknowledgements = 0
            return
        }
        entry.bytes = bytes; entries[key] = entry
    }
    public func key(at index: UInt32) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard Int(index) < orderedKeys.count else { throw SMCError.notFound }
        return orderedKeys[Int(index)]
    }
    public func value(_ key: String) throws -> Double { try SMCCodec.number(read(key)) }
    private func put(_ key: String, number: Double, type: String, size: Int) {
        guard let bytes = try? SMCCodec.bytes(number, type: type, size: size) else { return }
        lock.lock(); defer { lock.unlock() }
        if entries[key] == nil { orderedKeys.append(key) }
        entries[key] = Entry(info: SMCKeyInfo(size: size, type: type, attributes: 0), bytes: bytes)
    }
}
