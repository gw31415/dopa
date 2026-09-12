import Foundation
import XCTest

@testable import DopaProtocol

final class JSONWireTests: XCTestCase {
  func testRoundTripAndDeterministicObjectEncoding() throws {
    let value: JSONValue = .object([
      "message": .string("hello\n世界"),
      "enabled": .bool(true),
      "items": .array([.number(1.5), .null]),
    ])
    let encoded = try JSONWire.encode(value)
    XCTAssertEqual(String(decoding: encoded, as: UTF8.self).last, "\n")
    XCTAssertEqual(
      String(decoding: encoded, as: UTF8.self),
      "{\"enabled\":true,\"items\":[1.5,null],\"message\":\"hello\\n世界\"}\n")
    XCTAssertEqual(try JSONWire.decode(encoded), value)
  }

  func testLineBufferHandlesFragmentsAndMultipleMessages() throws {
    var buffer = JSONLineBuffer()
    XCTAssertEqual(try buffer.append(Data("{\"id\":\"1\"".utf8)), [])
    let values = try buffer.append(Data("}\n{\"id\":\"2\"}\n".utf8))
    XCTAssertEqual(values, [
      .object(["id": .string("1")]),
      .object(["id": .string("2")]),
    ])
  }

  func testRejectsDuplicateKeysAndInvalidFrames() throws {
    XCTAssertThrowsError(try JSONWire.decode(Data("{\"a\":1,\"a\":2}".utf8))) { error in
      XCTAssertEqual(error as? JSONWireError, .duplicateKey("a"))
    }
    XCTAssertThrowsError(try JSONWire.decode(Data("[1]".utf8))) { error in
      XCTAssertEqual(error as? JSONWireError, .topLevelMustBeObject)
    }
    XCTAssertThrowsError(try JSONWire.decode(Data("{\"a\":1}\r\n".utf8))) { error in
      XCTAssertEqual(error as? JSONWireError, .invalidFrame)
    }
    XCTAssertThrowsError(try JSONWire.decode(Data([0x7B, 0x22, 0x61, 0x22, 0x3A, 0xC3, 0x28, 0x7D]))) { error in
      XCTAssertEqual(error as? JSONWireError, .invalidUTF8)
    }
  }

  func testRejectsSizeDepthAndNonFiniteNumbers() throws {
    let oversized = JSONValue.object(["value": .string(String(repeating: "x", count: JSONWire.maxMessageBytes))])
    XCTAssertThrowsError(try JSONWire.encode(oversized)) { error in
      XCTAssertEqual(error as? JSONWireError, .messageTooLarge)
    }
    var deep: JSONValue = .object([:])
    for _ in 0..<(JSONWire.maxNestingDepth - 1) { deep = .object(["next": deep]) }
    XCTAssertNoThrow(try JSONWire.encode(deep))
    deep = .object(["next": deep])
    XCTAssertThrowsError(try JSONWire.encode(deep)) { error in
      XCTAssertEqual(error as? JSONWireError, .nestingTooDeep)
    }
    XCTAssertThrowsError(try JSONWire.encode(.object(["nan": .number(.nan)]))) { error in
      XCTAssertEqual(error as? JSONWireError, .invalidJSON("JSON numbers must be finite"))
    }
  }
}
