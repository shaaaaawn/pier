import Foundation
import IOKit

// Temperatures and fans, read from the System Management Controller.
//
// The calls are public IOKit (`IOServiceOpen` on "AppleSMC",
// `IOConnectCallStructMethod`), need no permission, and run as the user. What
// isn't documented is the vocabulary: four-character sensor keys whose names
// vary by chip. So nothing here hard-codes a model's key list — sensors are
// found by family (see `SMCSensors.cpuKeys`), and every caller degrades to
// "no temperature" when the SMC won't open or nothing qualifies.
//
// **Read-only by construction.** The only commands are the three reads below;
// the SMC's write command is deliberately absent, and a test fails if it ever
// appears. Verified on an M1 Max (2,122 keys, 217 temperature sensors).

/// The kernel's `SMCKeyData_t`. Layout matters: the driver checks the size
/// (80 bytes) and reads fields at fixed offsets. Flattening `keyInfo` into the
/// outer struct — an easy mistake — shifts every field after it and every
/// call fails. `SMCTests` pins the stride.
struct SMCKeyData {
  struct Version {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
  }
  struct PowerLimit {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpu: UInt32 = 0
    var gpu: UInt32 = 0
    var memory: UInt32 = 0
  }
  struct KeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
  }

  var key: UInt32 = 0
  var version = Version()
  var powerLimit = PowerLimit()
  var keyInfo = KeyInfo()
  var padding: UInt16 = 0
  var result: UInt8 = 0
  var status: UInt8 = 0
  var command: UInt8 = 0
  var index: UInt32 = 0
  var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
}

enum SMCCommand {
  /// The driver's one entry point (`kSMCHandleYPCEvent`).
  static let selector: UInt32 = 2
  /// Read a key's value.
  static let readBytes: UInt8 = 5
  /// The key at an index — used once, to discover which sensors exist.
  static let readIndex: UInt8 = 8
  /// A key's size and type.
  static let readKeyInfo: UInt8 = 9
  /// Every command this file sends. There is no write.
  static let all: Set<UInt8> = [readBytes, readIndex, readKeyInfo]
}

/// A sensor, with its size and type cached at discovery so a reading is a
/// single call.
struct SMCKey: Equatable, Sendable {
  let code: UInt32
  let size: UInt32
  let type: UInt32

  var name: String { SMCCodec.string(code) }
}

enum SMCCodec {
  static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

  static func string(_ code: UInt32) -> String {
    String(decoding: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }, as: UTF8.self)
  }

  static let floatType = fourCC("flt ")

  /// Apple-silicon SMC floats are little-endian IEEE-754.
  static func float(_ bytes: [UInt8]) -> Float? {
    guard bytes.count == 4 else { return nil }
    let bits = bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
    return Float(bitPattern: bits)
  }
}

/// A connection to AppleSMC. Not thread-safe: `SensorSampler` owns one and
/// uses it only on its own serial queue.
final class SMCConnection {
  private var connection: io_connect_t = 0

  init?() {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else {
      return nil
    }
  }

  deinit { IOServiceClose(connection) }

  private func call(_ input: SMCKeyData) -> SMCKeyData? {
    precondition(SMCCommand.all.contains(input.command), "SMC: read commands only")
    var input = input
    var output = SMCKeyData()
    var size = MemoryLayout<SMCKeyData>.stride
    let result = IOConnectCallStructMethod(
      connection, SMCCommand.selector, &input, MemoryLayout<SMCKeyData>.stride, &output, &size)
    return result == kIOReturnSuccess && output.result == 0 ? output : nil
  }

  func info(_ code: UInt32) -> SMCKey? {
    var input = SMCKeyData()
    input.key = code
    input.command = SMCCommand.readKeyInfo
    guard let out = call(input) else { return nil }
    return SMCKey(code: code, size: out.keyInfo.dataSize, type: out.keyInfo.dataType)
  }

  func bytes(_ key: SMCKey) -> [UInt8]? {
    var input = SMCKeyData()
    input.key = key.code
    input.command = SMCCommand.readBytes
    input.keyInfo.dataSize = key.size
    guard var out = call(input)?.bytes else { return nil }
    return withUnsafeBytes(of: &out) { Array($0.prefix(Int(min(key.size, 32)))) }
  }

  func float(_ key: SMCKey) -> Float? {
    guard key.type == SMCCodec.floatType, let raw = bytes(key) else { return nil }
    return SMCCodec.float(raw)
  }

  /// Every key, by index. ~2,000 calls (~0.5 s on an M1 Max): done once, off
  /// the main thread, the first time temperatures are wanted.
  func allKeys() -> [SMCKey] {
    guard let count = info(SMCCodec.fourCC("#KEY")).flatMap(bytes) else { return [] }
    let total = count.reduce(0) { $0 << 8 | Int($1) }
    return (0..<total).compactMap { index in
      var input = SMCKeyData()
      input.command = SMCCommand.readIndex
      input.index = UInt32(index)
      guard let code = call(input)?.key else { return nil }
      return info(code)
    }
  }
}
