import Foundation
import IOKit

public enum SMCError: Error, LocalizedError {
    case unavailable, transport(kern_return_t), badCommand, notFound, notWritable, sizeMismatch, notPrivileged, device(UInt8), malformed(String)
    public static func result(_ byte: UInt8) -> SMCError {
        switch byte {
        case 0x82: .badCommand
        case 0x84: .notFound
        case 0x86: .notWritable
        case 0x87: .sizeMismatch
        default: .device(byte)
        }
    }
    public var errorDescription: String? {
        switch self {
        case .unavailable: "AppleSMC service is unavailable"
        case .transport(let code) where code == kIOReturnNotPrivileged: "Administrator privileges are required to write fan settings"
        case .transport(let code): "IOKit error \(String(format: "0x%08x", UInt32(bitPattern: code)))"
        case .badCommand: "The SMC refused the command; its thermal manager may still own the fans"
        case .notFound: "The SMC key was not found"
        case .notWritable: "The SMC key is read-only"
        case .sizeMismatch: "The SMC reported a key size mismatch; read back before retrying"
        case .notPrivileged: "Administrator privileges are required to write fan settings"
        case .device(let code): "SMC returned \(String(format: "0x%02x", code))"
        case .malformed(let key): "SMC key \(key) has an unsupported encoding"
        }
    }
}

public struct SMCParamStruct {
    public var key: UInt32 = 0
    public var version = (major: UInt8(0), minor: UInt8(0), build: UInt8(0), release: UInt8(0), reserved0: UInt16(0), reserved1: UInt16(0), reserved2: UInt16(0), reserved3: UInt16(0))
    public var pLimit = (version: UInt16(0), length: UInt16(0), cpu: UInt32(0), gpu: UInt32(0))
    public var keyInfo = (size: UInt32(0), type: UInt32(0), attributes: UInt8(0), pad0: UInt8(0), pad1: UInt8(0), pad2: UInt8(0))
    public var result: UInt8 = 0
    public var status: UInt8 = 0
    public var data8: UInt8 = 0
    public var pad: UInt8 = 0
    public var data32: UInt32 = 0
    public var bytes = (UInt8(0),UInt8(0),UInt8(0),UInt8(0),UInt8(0),UInt8(0),UInt8(0),UInt8(0),UInt8(0),UInt8(0),UInt8(0),UInt8(0),UInt8(0),UInt8(0),UInt8(0),UInt8(0),UInt8(0),UInt8(0),UInt8(0),UInt8(0),UInt8(0),UInt8(0),UInt8(0),UInt8(0),UInt8(0),UInt8(0),UInt8(0),UInt8(0),UInt8(0),UInt8(0),UInt8(0),UInt8(0))
}

public struct SMCKeyInfo: Sendable { public let size: Int; public let type: String; public let attributes: UInt8 }
public struct SMCValue: Sendable { public let info: SMCKeyInfo; public let bytes: [UInt8] }

public protocol SMCDevice: Sendable {
    func keyInfo(_ key: String) throws -> SMCKeyInfo
    func read(_ key: String) throws -> SMCValue
    func write(_ key: String, bytes: [UInt8]) throws
    func key(at index: UInt32) throws -> String
}

public final class AppleSMC: SMCDevice, @unchecked Sendable {
    private var connection: io_connect_t = 0
    private let lock = NSLock()
    private var keyInfoCache: [String: SMCKeyInfo] = [:]
    public init() throws {
        guard let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC")) as io_service_t? else { throw SMCError.unavailable }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == KERN_SUCCESS else { throw SMCError.transport(result) }
    }
    deinit { if connection != 0 { IOServiceClose(connection) } }

    private func call(command: UInt8, key: String, setup: (inout SMCParamStruct) -> Void = { _ in }) throws -> SMCParamStruct {
        lock.lock(); defer { lock.unlock() }
        var input = SMCParamStruct()
        input.key = Self.fourCC(key); input.data8 = command; setup(&input)
        var output = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.stride
        let kr = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<SMCParamStruct>.stride, &output, &outSize)
        guard kr == KERN_SUCCESS else { throw kr == kIOReturnNotPrivileged ? SMCError.notPrivileged : SMCError.transport(kr) }
        guard output.result == 0 else { throw SMCError.result(output.result) }
        return output
    }
    public func keyInfo(_ key: String) throws -> SMCKeyInfo {
        lock.lock()
        if let cached = keyInfoCache[key] { lock.unlock(); return cached }
        lock.unlock()
        let out = try call(command: 9, key: key)
        let value = SMCKeyInfo(size: Int(out.keyInfo.size), type: Self.string(from: out.keyInfo.type), attributes: out.keyInfo.attributes)
        lock.lock(); keyInfoCache[key] = value; lock.unlock()
        return value
    }
    public func read(_ key: String) throws -> SMCValue {
        let info = try keyInfo(key)
        var out = try call(command: 5, key: key) { $0.keyInfo.size = UInt32(info.size) }
        let all = withUnsafeBytes(of: &out.bytes) { Array($0.prefix(min(info.size, 32))) }
        return SMCValue(info: info, bytes: all)
    }
    public func write(_ key: String, bytes: [UInt8]) throws {
        let info = try keyInfo(key)
        guard bytes.count == info.size, bytes.count <= 32 else { throw SMCError.malformed(key) }
        _ = try call(command: 6, key: key) { p in
            p.keyInfo.size = UInt32(info.size)
            withUnsafeMutableBytes(of: &p.bytes) { dest in dest.copyBytes(from: bytes) }
        }
    }
    public func key(at index: UInt32) throws -> String {
        let out = try call(command: 8, key: "\0\0\0\0") { $0.data32 = index }
        return Self.string(from: out.key)
    }
    public static func fourCC(_ s: String) -> UInt32 {
        let b = Array(s.utf8.prefix(4)) + Array(repeating: 0, count: max(0, 4 - s.utf8.count))
        return b.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    public static func string(from x: UInt32) -> String { String(bytes: [UInt8(x >> 24), UInt8(truncatingIfNeeded: x >> 16), UInt8(truncatingIfNeeded: x >> 8), UInt8(truncatingIfNeeded: x)], encoding: .macOSRoman) ?? "????" }
}

public enum SMCCodec {
    public static func number(_ value: SMCValue) throws -> Double {
        let b = value.bytes
        guard b.count == value.info.size else { throw SMCError.malformed("\(value.info.type) byte count") }
        switch (value.info.type, value.info.size) {
        case ("flt ", 4): let bits = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24; return Double(Float(bitPattern: bits))
        case ("sp78", 2): let n = Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1])); return Double(n) / 256
        case ("fpe2", 2): return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4
        case ("ui8 ", 1): return Double(b[0])
        case ("ui16", 2): return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case ("ui32", 4): return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        default: throw SMCError.malformed(value.info.type)
        }
    }
    public static func bytes(_ value: Double, type: String, size: Int) throws -> [UInt8] {
        guard value.isFinite else { throw SMCError.malformed(type) }
        switch (type, size) {
        case ("flt ", 4):
            let float = Float(value); guard float.isFinite else { throw SMCError.malformed(type) }
            let x = float.bitPattern
            return [UInt8(truncatingIfNeeded: x), UInt8(truncatingIfNeeded: x >> 8), UInt8(truncatingIfNeeded: x >> 16), UInt8(truncatingIfNeeded: x >> 24)]
        case ("sp78", 2):
            let fixed = (value * 256).rounded()
            guard (-32768.0...32767.0).contains(fixed) else { throw SMCError.malformed(type) }
            let x = UInt16(bitPattern: Int16(fixed))
            return [UInt8(truncatingIfNeeded: x >> 8), UInt8(truncatingIfNeeded: x)]
        case ("fpe2", 2):
            let fixed = (value * 4).rounded()
            guard (0.0...65535.0).contains(fixed) else { throw SMCError.malformed(type) }
            let x = UInt16(fixed)
            return [UInt8(truncatingIfNeeded: x >> 8), UInt8(truncatingIfNeeded: x)]
        case ("ui8 ", 1):
            let rounded = value.rounded()
            guard (0.0...255.0).contains(rounded) else { throw SMCError.malformed(type) }
            return [UInt8(rounded)]
        case ("ui16", 2):
            let rounded = value.rounded()
            guard (0.0...65535.0).contains(rounded) else { throw SMCError.malformed(type) }
            let x = UInt16(rounded)
            return [UInt8(truncatingIfNeeded: x >> 8), UInt8(truncatingIfNeeded: x)]
        case ("ui32", 4):
            let rounded = value.rounded()
            guard (0.0...4_294_967_295.0).contains(rounded) else { throw SMCError.malformed(type) }
            let x = UInt32(rounded)
            return [UInt8(truncatingIfNeeded: x >> 24), UInt8(truncatingIfNeeded: x >> 16), UInt8(truncatingIfNeeded: x >> 8), UInt8(truncatingIfNeeded: x)]
        default: throw SMCError.malformed(type)
        }
    }
}

public enum SMCLayout {
    public static func validate() -> Bool {
        MemoryLayout<SMCParamStruct>.stride == 80 &&
        MemoryLayout<SMCParamStruct>.offset(of: \.keyInfo) == 28 &&
        MemoryLayout<SMCParamStruct>.offset(of: \.result) == 40 &&
        MemoryLayout<SMCParamStruct>.offset(of: \.data8) == 42
    }
}
