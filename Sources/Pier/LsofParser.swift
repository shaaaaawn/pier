import Foundation

/// One parsed row of lsof output.
struct LsofRecord: Equatable {
  let command: String
  let pid: Int32
  let user: String
  let proto: PortProtocol
  let bindAddress: String
  let port: Int
}

/// Parser for `lsof -nP -iTCP -sTCP:LISTEN` and `lsof -nP -iUDP` output.
enum LsofParser {
  static func parse(_ output: String, proto: PortProtocol) -> [LsofRecord] {
    output.split(separator: "\n").compactMap { parseLine(String($0), proto: proto) }
  }

  /// Columns: COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME (state)
  static func parseLine(_ line: String, proto: PortProtocol) -> LsofRecord? {
    if line.hasPrefix("COMMAND") { return nil }
    let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    guard tokens.count >= 9, let pid = Int32(tokens[1]) else { return nil }
    // The NAME column is the first token at index >= 8 that parses as addr:port.
    for i in 8..<tokens.count {
      let token = tokens[i]
      if token == "(LISTEN)" { continue }
      // Connected endpoint (addr:port->peer:port), not a bound socket.
      if token.contains("->") { return nil }
      guard let (address, port) = splitAddress(token) else { continue }
      return LsofRecord(
        command: unescape(tokens[0]), pid: pid, user: tokens[2],
        proto: proto, bindAddress: address, port: port
      )
    }
    return nil
  }

  /// lsof escapes non-printables and **spaces** in COMMAND as `\xNN` so its
  /// columns stay whitespace-separable — "Cursor\x20Helper\x20(Plugin)". Decode
  /// it for display; do this *after* tokenizing, never before, or the escaping
  /// stops doing its job.
  static func unescape(_ command: String) -> String {
    guard command.contains("\\x") else { return command }
    var out = ""
    var rest = Substring(command)
    while let range = rest.range(of: "\\x") {
      out += rest[..<range.lowerBound]
      let after = rest[range.upperBound...]
      let hex = after.prefix(2)
      if hex.count == 2, let value = UInt8(hex, radix: 16),
        let scalar = Unicode.Scalar(value) as Unicode.Scalar?
      {
        out.append(Character(scalar))
        rest = after.dropFirst(2)
      } else {
        out += "\\x"
        rest = after
      }
    }
    out += rest
    return out
  }

  /// Split "127.0.0.1:8080", "[::1]:8080", "*:5353" into (address, port).
  static func splitAddress(_ token: String) -> (String, Int)? {
    guard let idx = token.lastIndex(of: ":") else { return nil }
    guard let port = Int(token[token.index(after: idx)...]) else { return nil }
    var address = String(token[..<idx])
    if address.hasPrefix("[") && address.hasSuffix("]") {
      address = String(address.dropFirst().dropLast())
    }
    if address.isEmpty { return nil }
    return (address, port)
  }
}
