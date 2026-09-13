import Foundation

public enum JSONWireError: Error, Equatable, Sendable, CustomStringConvertible {
  case invalidUTF8
  case invalidJSON(String)
  case duplicateKey(String)
  case messageTooLarge
  case invalidFrame
  case topLevelMustBeObject
  case nestingTooDeep

  public var description: String {
    switch self {
    case .invalidUTF8: return "invalid UTF-8"
    case .invalidJSON(let message): return "invalid JSON: \(message)"
    case .duplicateKey(let key): return "duplicate object key: \(key)"
    case .messageTooLarge: return "JSON message exceeds 65536 bytes"
    case .invalidFrame: return "invalid NDJSON frame"
    case .topLevelMustBeObject: return "top-level JSON value must be an object"
    case .nestingTooDeep: return "JSON nesting exceeds 32 levels"
    }
  }
}

public enum JSONWire {
  public static let maxMessageBytes = 64 * 1024
  public static let maxNestingDepth = 32

  /// Encodes one JSON object as a UTF-8 NDJSON frame.
  ///
  /// The returned data always ends in exactly one LF. The LF is not counted
  /// toward the 64 KiB message limit.
  ///
  /// Validation runs before any output bytes are produced, so invalid input
  /// keeps reporting its original error (nesting, non-finite numbers, and the
  /// top-level object requirement) even when the message is also oversized.
  /// Only valid-but-oversized input fails with `messageTooLarge`, which the
  /// writer throws as soon as the byte count crosses the limit instead of
  /// materializing the full oversized frame.
  public static func encode(_ value: JSONValue) throws -> Data {
    guard case .object = value else { throw JSONWireError.topLevelMustBeObject }
    try validate(value, depth: 0)
    var writer = JSONWriter()
    try writer.write(value)
    // The writer already throws on overflow; this guard documents and defends
    // the frame limit at the boundary that owns it.
    guard writer.data.count <= maxMessageBytes else {
      throw JSONWireError.messageTooLarge
    }
    writer.data.append(0x0A)
    return writer.data
  }

  private static func validate(_ value: JSONValue, depth: Int) throws {
    switch value {
    case .object(let object):
      guard depth < maxNestingDepth else { throw JSONWireError.nestingTooDeep }
      for (key, child) in object {
        _ = key
        try validate(child, depth: depth + 1)
      }
    case .array(let array):
      guard depth < maxNestingDepth else { throw JSONWireError.nestingTooDeep }
      for child in array { try validate(child, depth: depth + 1) }
    case .number(let number):
      guard number.isFinite else {
        throw JSONWireError.invalidJSON("JSON numbers must be finite")
      }
    case .string, .bool, .null:
      break
    }
  }

  /// Decodes one JSON object. A single trailing LF is accepted for callers
  /// that have a complete NDJSON frame; the line buffer strips it itself.
  public static func decode(_ data: Data) throws -> JSONValue {
    var bytes = Array(data)
    if bytes.last == 0x0A { bytes.removeLast() }
    guard !bytes.isEmpty, bytes.count <= maxMessageBytes else {
      throw bytes.isEmpty ? JSONWireError.invalidFrame : JSONWireError.messageTooLarge
    }
    guard !bytes.contains(0x0A), !bytes.contains(0x0D) else {
      throw JSONWireError.invalidFrame
    }
    guard String(bytes: bytes, encoding: .utf8) != nil else {
      throw JSONWireError.invalidUTF8
    }
    var parser = JSONParser(bytes: bytes)
    let result = try parser.parse()
    guard case .object = result else { throw JSONWireError.topLevelMustBeObject }
    return result
  }
}

/// Accumulates arbitrary socket reads and emits complete NDJSON objects.
public struct JSONLineBuffer: Sendable {
  // Optionality is intentional: assigning nil after a rare large frame drops
  // Data's backing allocation instead of retaining it for the lifetime of an
  // otherwise idle connection.
  private var pending: Data? = Data()
  /// Largest `pending.count` reached since the last buffer release. `Data`
  /// exposes no `capacity` accessor on this toolchain, so this byte high-water
  /// is the observable lower bound of the retained buffer storage.
  private var peakPendingBytes = 0
  // Common requests remain below this boundary. Frames at or above it release
  // their backing storage once decoded, including near-limit frames that never
  // reach the public 64 KiB maximum.
  static let retainedBufferReleaseThreshold = JSONWire.maxMessageBytes / 2

  // Internal observability for the memory-retention policy's regression tests.
  var hasRetainedPendingStorage: Bool { pending != nil }
  var retainedPendingHighWaterBytes: Int { peakPendingBytes }

  public init() {}

  public mutating func append(_ data: Data) throws -> [JSONValue] {
    var values: [JSONValue] = []
    for byte in data {
      if byte == 0x0A {
        guard let frame = pending, !frame.isEmpty else { throw JSONWireError.invalidFrame }
        // `pending.count` grows monotonically within a frame, so the peak only
        // needs recording at frame completion (and at overflow below) instead
        // of on every byte.
        if frame.count > peakPendingBytes { peakPendingBytes = frame.count }
        values.append(try JSONWire.decode(frame))
        if peakPendingBytes >= Self.retainedBufferReleaseThreshold {
          pending = nil
          peakPendingBytes = 0
        } else {
          pending?.removeAll(keepingCapacity: true)
        }
      } else {
        guard byte != 0x0D else { throw JSONWireError.invalidFrame }
        if pending == nil { pending = Data() }
        pending!.append(byte)
        guard pending!.count <= JSONWire.maxMessageBytes else {
          peakPendingBytes = pending!.count
          throw JSONWireError.messageTooLarge
        }
      }
    }
    return values
  }
}

private struct JSONWriter {
  var data = Data()

  // Four lowercase hex digits per control scalar 0x00...0x1F, matching the
  // "\u00xx" escape (without the leading backslash and 'u') that
  // String(format: "%04x") produced. Precomputed so control escapes do not
  // pay a Foundation format call per scalar.
  private static let controlEscapeHex: [UInt8] = {
    let hexDigits = Array("0123456789abcdef".utf8)
    var table: [UInt8] = []
    table.reserveCapacity(32 * 4)
    for value in 0...31 {
      table.append(0x30) // "0"
      table.append(0x30) // "0"
      table.append(hexDigits[(value >> 4) & 0xF])
      table.append(hexDigits[value & 0xF])
    }
    return table
  }()

  mutating func write(_ value: JSONValue) throws {
    switch value {
    case .object(let object):
      try append(0x7B) // {
      let keys = object.keys.sorted {
        $0.utf8.lexicographicallyPrecedes($1.utf8)
      }
      for (index, key) in keys.enumerated() {
        if index != 0 { try append(0x2C) } // ,
        try write(string: key)
        try append(0x3A) // :
        try write(object[key]!)
      }
      try append(0x7D) // }
    case .array(let array):
      try append(0x5B) // [
      for (index, element) in array.enumerated() {
        if index != 0 { try append(0x2C) }
        try write(element)
      }
      try append(0x5D) // ]
    case .string(let string):
      try write(string: string)
    case .bool(let value):
      try append(contentsOf: value ? [0x74, 0x72, 0x75, 0x65] : [0x66, 0x61, 0x6C, 0x73, 0x65])
    case .number(let value):
      // JSONWire.encode validates this before appending the LF. Keeping the
      // fallback here avoids silently emitting invalid JSON if the writer is
      // reused in the future.
      if value.isFinite {
        try append(contentsOf: String(value).utf8)
      }
    case .null:
      try append(contentsOf: [0x6E, 0x75, 0x6C, 0x6C])
    }
  }

  mutating func write(string: String) throws {
    try append(0x22) // "
    for scalar in string.unicodeScalars {
      switch scalar.value {
      case 0x22: try append(contentsOf: [0x5C, 0x22])
      case 0x5C: try append(contentsOf: [0x5C, 0x5C])
      case 0x08: try append(contentsOf: [0x5C, 0x62])
      case 0x0C: try append(contentsOf: [0x5C, 0x66])
      case 0x0A: try append(contentsOf: [0x5C, 0x6E])
      case 0x0D: try append(contentsOf: [0x5C, 0x72])
      case 0x09: try append(contentsOf: [0x5C, 0x74])
      case 0x00...0x1F:
        try append(contentsOf: [0x5C, 0x75])
        let digits = Int(scalar.value) * 4
        try append(contentsOf: Self.controlEscapeHex[digits..<(digits + 4)])
      default:
        try append(contentsOf: String(scalar).utf8)
      }
    }
    try append(0x22)
  }

  /// All frame bytes flow through these two entry points so output that would
  /// exceed the 64 KiB message limit is rejected as soon as the count crosses
  /// the limit, before the oversized frame is fully materialized. The largest
  /// single append is one number's textual form, so `data` stays bounded just
  /// past the limit instead of growing with the whole oversized message.
  private mutating func append(_ byte: UInt8) throws {
    data.append(byte)
    if data.count > JSONWire.maxMessageBytes { throw JSONWireError.messageTooLarge }
  }

  private mutating func append<Bytes: Sequence>(contentsOf bytes: Bytes) throws where Bytes.Element == UInt8 {
    data.append(contentsOf: bytes)
    if data.count > JSONWire.maxMessageBytes { throw JSONWireError.messageTooLarge }
  }
}

private struct JSONParser {
  let bytes: [UInt8]
  var index = 0

  mutating func parse() throws -> JSONValue {
    skipWhitespace()
    let value = try parseValue(depth: 0)
    skipWhitespace()
    guard index == bytes.count else { throw error("trailing data") }
    return value
  }

  mutating private func parseValue(depth: Int) throws -> JSONValue {
    guard index < bytes.count else { throw error("unexpected end of input") }
    switch bytes[index] {
    case 0x7B: return try parseObject(depth: depth)
    case 0x5B: return try parseArray(depth: depth)
    case 0x22: return .string(try parseString())
    case 0x74: try consumeLiteral("true"); return .bool(true)
    case 0x66: try consumeLiteral("false"); return .bool(false)
    case 0x6E: try consumeLiteral("null"); return .null
    case 0x2D, 0x30...0x39: return .number(try parseNumber())
    default: throw error("unexpected byte")
    }
  }

  mutating private func parseObject(depth: Int) throws -> JSONValue {
    try enterContainer(depth)
    index += 1
    skipWhitespace()
    var object: [String: JSONValue] = [:]
    if consume(0x7D) { return .object(object) }
    while true {
      guard index < bytes.count, bytes[index] == 0x22 else {
        throw error("object key must be a string")
      }
      let key = try parseString()
      guard object[key] == nil else { throw JSONWireError.duplicateKey(key) }
      skipWhitespace()
      guard consume(0x3A) else { throw error("missing object colon") }
      skipWhitespace()
      object[key] = try parseValue(depth: depth + 1)
      skipWhitespace()
      if consume(0x7D) { return .object(object) }
      guard consume(0x2C) else { throw error("missing object comma") }
      skipWhitespace()
    }
  }

  mutating private func parseArray(depth: Int) throws -> JSONValue {
    try enterContainer(depth)
    index += 1
    skipWhitespace()
    var array: [JSONValue] = []
    if consume(0x5D) { return .array(array) }
    while true {
      array.append(try parseValue(depth: depth + 1))
      skipWhitespace()
      if consume(0x5D) { return .array(array) }
      guard consume(0x2C) else { throw error("missing array comma") }
      skipWhitespace()
    }
  }

  mutating private func parseString() throws -> String {
    guard consume(0x22) else { throw error("expected string") }
    var output = String.UnicodeScalarView()
    while index < bytes.count {
      let byte = bytes[index]
      index += 1
      switch byte {
      case 0x22:
        return String(output)
      case 0x5C:
        guard index < bytes.count else { throw error("unfinished escape") }
        let escaped = bytes[index]
        index += 1
        switch escaped {
        case 0x22: output.append("\"")
        case 0x5C: output.append("\\")
        case 0x2F: output.append("/")
        case 0x62: output.append("\u{8}")
        case 0x66: output.append("\u{c}")
        case 0x6E: output.append("\n")
        case 0x72: output.append("\r")
        case 0x74: output.append("\t")
        case 0x75:
          try appendUnicodeEscape(to: &output)
        default:
          throw error("invalid string escape")
        }
      case 0x00...0x1F:
        throw error("unescaped control character in string")
      case 0x80...0xFF:
        // Decode a complete UTF-8 scalar from the source bytes. This keeps
        // malformed UTF-8 from being replaced by U+FFFD.
        let start = index - 1
        let width: Int
        if byte >= 0xC2 && byte <= 0xDF { width = 2 }
        else if byte >= 0xE0 && byte <= 0xEF { width = 3 }
        else if byte >= 0xF0 && byte <= 0xF4 { width = 4 }
        else { throw JSONWireError.invalidUTF8 }
        guard index + width - 1 <= bytes.count else { throw JSONWireError.invalidUTF8 }
        for continuation in bytes[index..<(index + width - 1)] {
          guard continuation & 0xC0 == 0x80 else { throw JSONWireError.invalidUTF8 }
        }
        let scalarBytes = bytes[start..<(start + width)]
        guard let scalar = String(decoding: scalarBytes, as: UTF8.self).unicodeScalars.first,
          String(decoding: scalarBytes, as: UTF8.self).unicodeScalars.count == 1
        else { throw JSONWireError.invalidUTF8 }
        output.append(scalar)
        index += width - 1
      default:
        output.append(UnicodeScalar(byte))
      }
    }
    throw error("unterminated string")
  }

  mutating private func appendUnicodeEscape(to output: inout String.UnicodeScalarView) throws {
    let first = try readHexQuad()
    if (0xD800...0xDBFF).contains(first) {
      guard index + 1 < bytes.count, bytes[index] == 0x5C, bytes[index + 1] == 0x75 else {
        throw error("high surrogate is not followed by a low surrogate")
      }
      index += 2
      let second = try readHexQuad()
      guard (0xDC00...0xDFFF).contains(second) else { throw error("invalid low surrogate") }
      let scalarValue = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
      guard let scalar = UnicodeScalar(scalarValue) else { throw JSONWireError.invalidJSON("invalid Unicode scalar") }
      output.append(scalar)
    } else if (0xDC00...0xDFFF).contains(first) {
      throw error("unexpected low surrogate")
    } else {
      guard let scalar = UnicodeScalar(first) else { throw JSONWireError.invalidJSON("invalid Unicode scalar") }
      output.append(scalar)
    }
  }

  mutating private func readHexQuad() throws -> UInt32 {
    guard index + 4 <= bytes.count else { throw error("short Unicode escape") }
    var value: UInt32 = 0
    for _ in 0..<4 {
      guard let digit = hexValue(bytes[index]) else { throw error("invalid Unicode escape") }
      value = value * 16 + digit
      index += 1
    }
    return value
  }

  mutating private func parseNumber() throws -> Double {
    let start = index
    if consume(0x2D) {}
    if consume(0x30) {
      if index < bytes.count, (0x30...0x39).contains(bytes[index]) {
        throw error("leading zero in number")
      }
    } else {
      guard consumeDigits(minimum: 1) else { throw error("invalid number") }
    }
    if consume(0x2E) {
      guard consumeDigits(minimum: 1) else { throw error("fraction has no digits") }
    }
    if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
      index += 1
      if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
      guard consumeDigits(minimum: 1) else { throw error("exponent has no digits") }
    }
    let string = String(decoding: bytes[start..<index], as: UTF8.self)
    guard let value = Double(string), value.isFinite else { throw error("number is out of range") }
    return value
  }

  mutating private func consumeLiteral(_ literal: String) throws {
    let expected = Array(literal.utf8)
    guard index + expected.count <= bytes.count,
      bytes[index..<(index + expected.count)].elementsEqual(expected)
    else { throw error("invalid literal") }
    index += expected.count
  }

  mutating private func consumeDigits(minimum: Int) -> Bool {
    let start = index
    while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
    return index - start >= minimum
  }

  mutating private func enterContainer(_ depth: Int) throws {
    guard depth < JSONWire.maxNestingDepth else { throw JSONWireError.nestingTooDeep }
  }

  mutating private func consume(_ byte: UInt8) -> Bool {
    guard index < bytes.count, bytes[index] == byte else { return false }
    index += 1
    return true
  }

  mutating private func skipWhitespace() {
    while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 { index += 1 }
  }

  private func error(_ message: String) -> JSONWireError {
    .invalidJSON(message)
  }

  private func hexValue(_ byte: UInt8) -> UInt32? {
    switch byte {
    case 0x30...0x39: return UInt32(byte - 0x30)
    case 0x41...0x46: return UInt32(byte - 0x41 + 10)
    case 0x61...0x66: return UInt32(byte - 0x61 + 10)
    default: return nil
    }
  }
}
