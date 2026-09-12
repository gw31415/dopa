import Foundation

public enum DopaProtocol {
  public static let apiVersion = 1
  public static let clientVersion = "0.2.1"
}

/// The JSON value types accepted by the Dopa wire protocol.
public enum JSONValue: Codable, Equatable, Sendable {
  case object([String: JSONValue])
  case array([JSONValue])
  case string(String)
  case bool(Bool)
  case number(Double)
  case null

  public var objectValue: [String: JSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  public var arrayValue: [JSONValue]? {
    guard case .array(let value) = self else { return nil }
    return value
  }

  public var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  public var boolValue: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }

  public var isNull: Bool {
    if case .null = self { return true }
    return false
  }

  public subscript(key: String) -> JSONValue? {
    objectValue?[key]
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self), value.isFinite {
      self = .number(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "value is not a supported JSON value")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .object(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .string(let value):
      try container.encode(value)
    case .bool(let value):
      try container.encode(value)
    case .number(let value):
      guard value.isFinite else {
        throw EncodingError.invalidValue(
          value,
          EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "JSON numbers must be finite"))
      }
      try container.encode(value)
    case .null:
      try container.encodeNil()
    }
  }
}
