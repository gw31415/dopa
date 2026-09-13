import DopaProtocol
import Foundation

public struct SessionOptions: Equatable, Sendable {
  public var keepDisplayOn = false
  public var stopOnLidClose = false
  public init(keepDisplayOn: Bool = false, stopOnLidClose: Bool = false) {
    self.keepDisplayOn = keepDisplayOn
    self.stopOnLidClose = stopOnLidClose
  }
  public var json: JSONValue {
    .object(["keepDisplayOn": .bool(keepDisplayOn), "stopOnLidClose": .bool(stopOnLidClose)])
  }
}

public struct DaemonSession: Identifiable, Equatable, Sendable {
  public let id: String
  public let clientName: String
  public let peerPID: Int32
  public let peerUID: UInt32?
  public let options: SessionOptions
}

public struct DaemonSnapshot: Equatable, Sendable {
  public let instanceID: String
  public let revision: String
  public let phase: String
  public let sessions: [DaemonSession]
  public let systemSleepDisabled: Bool?
  public let keepDisplayOn: Bool?
  public let recoveryPending: Bool
  public let error: String?

  public init(_ value: JSONValue) throws {
    guard let instance = value["instanceId"]?.stringValue,
      let revision = value["revision"]?.stringValue, !revision.isEmpty,
      revision.utf8.allSatisfy({ (48...57).contains($0) }),
      let phase = value["phase"]?.stringValue,
      let list = value["sessions"]?.arrayValue,
      let recovery = value["recoveryPending"]?.boolValue,
      value["confirmed"]?.objectValue != nil
    else { throw SnapshotError.malformed }
    self.instanceID = instance
    self.revision = revision
    self.phase = phase
    self.recoveryPending = recovery
    self.systemSleepDisabled = value["confirmed"]?["systemSleepDisabled"]?.boolValue
    self.keepDisplayOn = value["confirmed"]?["keepDisplayOn"]?.boolValue
    self.error = value["lastError"]?["message"]?.stringValue
    // Decode and duplicate-check sessions in one pass; duplicate session IDs
    // reject the whole snapshot, and the list order is preserved as decoded.
    var decodedSessions: [DaemonSession] = []
    decodedSessions.reserveCapacity(list.count)
    var seenIDs = Set<String>()
    seenIDs.reserveCapacity(list.count)
    for item in list {
      guard let id = item["id"]?.stringValue,
        let name = item["clientName"]?.stringValue,
        case .number(let pid) = item["peerPID"], let processID = Int32(exactly: pid),
        let display = item["options"]?["keepDisplayOn"]?.boolValue,
        let lid = item["options"]?["stopOnLidClose"]?.boolValue
      else { throw SnapshotError.malformed }
      guard seenIDs.insert(id).inserted else { throw SnapshotError.malformed }
      let peerUID: UInt32?
      if let value = item["peerUID"] {
        guard case .number(let uid) = value, let parsed = UInt32(exactly: uid) else {
          throw SnapshotError.malformed
        }
        peerUID = parsed
      } else { peerUID = nil }
      decodedSessions.append(DaemonSession(id: id, clientName: name, peerPID: processID, peerUID: peerUID,
        options: SessionOptions(keepDisplayOn: display, stopOnLidClose: lid)))
    }
    self.sessions = decodedSessions
  }

  /// Decimal revisions must never pass through floating-point numbers.
  public func isAtLeastAsNew(as previous: DaemonSnapshot) -> Bool {
    guard instanceID == previous.instanceID else { return true }
    return Self.revision(revision, isAtLeast: previous.revision)
  }

  public static func revision(_ current: String, isAtLeast previous: String) -> Bool {
    let lhs = current.drop(while: { $0 == "0" })
    let rhs = previous.drop(while: { $0 == "0" })
    return lhs.count == rhs.count ? lhs >= rhs : lhs.count > rhs.count
  }

  public var isConfirmed: Bool {
    guard phase == "idle" || phase == "active", let systemSleepDisabled,
      let keepDisplayOn else { return false }
    return systemSleepDisabled == !sessions.isEmpty
      && keepDisplayOn == sessions.contains(where: { $0.options.keepDisplayOn })
      && !(sessions.isEmpty && recoveryPending)
  }
}

public enum SnapshotError: Error { case malformed }
