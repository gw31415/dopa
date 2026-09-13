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

  func testEncodeAcceptsExactlyMaxMessageBytesAndRejectsOneMore() throws {
    // The frame is {"value":"…"}: 10 bytes before the payload, 2 after.
    let framing = "{\"value\":\"".utf8.count + 2
    let exactPayload = String(repeating: "x", count: JSONWire.maxMessageBytes - framing)
    let exact = try JSONWire.encode(.object(["value": .string(exactPayload)]))
    XCTAssertEqual(exact.count, JSONWire.maxMessageBytes + 1) // + trailing LF

    let oversizedPayload = String(repeating: "x", count: JSONWire.maxMessageBytes - framing + 1)
    XCTAssertThrowsError(try JSONWire.encode(.object(["value": .string(oversizedPayload)]))) { error in
      XCTAssertEqual(error as? JSONWireError, .messageTooLarge)
    }

    // Overflow reached through many small appends must fail the same way as a
    // single oversized string.
    let manyNumbers = JSONValue.object(["items": .array((0..<24_000).map { _ in .number(3.5) })])
    XCTAssertThrowsError(try JSONWire.encode(manyNumbers)) { error in
      XCTAssertEqual(error as? JSONWireError, .messageTooLarge)
    }
  }

  func testEncodeValidateErrorsTakePriorityOverOversizedOutput() {
    let big = String(repeating: "x", count: JSONWire.maxMessageBytes)
    var deep: JSONValue = .object([:])
    for _ in 0..<JSONWire.maxNestingDepth { deep = .object(["next": deep]) }
    XCTAssertThrowsError(try JSONWire.encode(.object(["pad": .string(big), "next": deep]))) { error in
      XCTAssertEqual(error as? JSONWireError, .nestingTooDeep)
    }
    XCTAssertThrowsError(try JSONWire.encode(.object(["pad": .string(big), "nan": .number(.nan)]))) { error in
      XCTAssertEqual(error as? JSONWireError, .invalidJSON("JSON numbers must be finite"))
    }
    XCTAssertThrowsError(try JSONWire.encode(.array([.string(big)]))) { error in
      XCTAssertEqual(error as? JSONWireError, .topLevelMustBeObject)
    }
  }

  func testLineBufferContinuesAfterMaxSizeFrame() throws {
    let framing = "{\"value\":\"".utf8.count + 2
    let payload = String(repeating: "x", count: JSONWire.maxMessageBytes - framing)
    let value = JSONValue.object(["value": .string(payload)])
    var buffer = JSONLineBuffer()
    XCTAssertEqual(try buffer.append(try JSONWire.encode(value)), [value])
    XCTAssertEqual(
      try buffer.append(Data("{\"id\":\"2\"}\n".utf8)),
      [.object(["id": .string("2")])])
  }

  func testLineBufferReleasesStorageAfterSubLimitHighWater() throws {
    let framing = "{\"value\":\"".utf8.count + 2
    let payloadSize = JSONLineBuffer.retainedBufferReleaseThreshold + 4_096 - framing
    let value = JSONValue.object(["value": .string(String(repeating: "x", count: payloadSize))])
    var buffer = JSONLineBuffer()

    XCTAssertEqual(try buffer.append(try JSONWire.encode(value)), [value])
    XCTAssertLessThan(payloadSize + framing, JSONWire.maxMessageBytes)
    XCTAssertFalse(buffer.hasRetainedPendingStorage)
    XCTAssertEqual(buffer.retainedPendingHighWaterBytes, 0)

    // Releasing the allocation must not change fragmented follow-up parsing.
    XCTAssertEqual(try buffer.append(Data("{\"id\":\"2\"".utf8)), [])
    XCTAssertTrue(buffer.hasRetainedPendingStorage)
    XCTAssertEqual(
      try buffer.append(Data("}\n".utf8)),
      [.object(["id": .string("2")])])
  }

  func testControlEscapesAndUTF8KeyOrderUnchanged() throws {
    let value: JSONValue = .object([
      "z": .number(1),
      "é": .number(2),
      "Z": .number(3),
      "\u{1}": .number(4),
    ])
    let encoded = try JSONWire.encode(value)
    XCTAssertEqual(
      String(decoding: encoded, as: UTF8.self),
      "{\"\\u0001\":4.0,\"Z\":3.0,\"z\":1.0,\"é\":2.0}\n")
    XCTAssertEqual(try JSONWire.decode(encoded), value)

    let controlString = try JSONWire.encode(.object(["c": .string("\u{0}\u{b}\u{1f}")]))
    XCTAssertEqual(
      String(decoding: controlString, as: UTF8.self),
      "{\"c\":\"\\u0000\\u000b\\u001f\"}\n")
  }
}
