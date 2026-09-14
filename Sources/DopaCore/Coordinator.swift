import CDopa
import Darwin
import Foundation

// All power changes are serialized here. A frontend owns only its connection;
// losing the original frontend never transfers or releases other sessions.
final class Coordinator {
  private final class Client {
    let channel: Descriptor
    let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
    var options: Options?
    var ready = false
    var completion: UInt8?
    init(_ channel: Descriptor) { self.channel = channel }
  }

  private let listener: Int32
  private let state: State
  private let power: any Power
  private let controls: any DisplayControls
  private var clients: [Client] = []
  private var inhibiting = false
  private var displaying = false

  init(listener: Int32, state: State, power: any Power, controls: any DisplayControls) {
    self.listener = listener
    self.state = state
    self.power = power
    self.controls = controls
  }

  func run() throws {
    var failure: Error?
    do { try monitor() } catch { failure = error }
    // On every failure, try both cleanup operations and retain the journal if
    // restoration fails. Notify clients only after these attempts complete.
    var errors: [String] = []
    do { try controls.releaseDisplay() } catch { errors.append("display release: \(error)") }
    do { try Session.recover(power: power, state: state) } catch {
      errors.append("restoration: \(error); journal retained at \(state.path)")
    }
    if !errors.isEmpty {
      failure = DopaError((failure.map { "\($0); " } ?? "") + errors.joined(separator: "; "))
    }
    for client in clients {
      _ = Wire.send(failure == nil ? Wire.done : Wire.failed, to: client.channel.value)
    }
    clients.removeAll()
    if let failure { throw failure }
  }

  private func monitor() throws {
    let startupDeadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
    var acceptedClient = false
    while true {
      if dopa_stop_requested() != 0 { return }
      var descriptors =
        [pollfd(fd: listener, events: Int16(POLLIN), revents: 0)]
        + clients.map { pollfd(fd: $0.channel.value, events: Int16(POLLIN), revents: 0) }
      let count = poll(&descriptors, nfds_t(descriptors.count), 100)
      if count < 0 {
        if errno == EINTR { continue }
        throw systemError("poll sessions")
      }
      guard descriptors[0].revents & Int16(POLLERR | POLLNVAL | POLLHUP) == 0 else {
        throw DopaError("guardian listener failed")
      }
      var readable = Set(descriptors.dropFirst().filter { $0.revents != 0 }.map { $0.fd })
      if descriptors[0].revents & Int16(POLLIN) != 0 {
        // Bound each batch so an incoming burst cannot starve existing clients.
        for _ in 0..<32 {
          guard let channel = try LocalSocket.accept(listener: listener) else { break }
          clients.append(Client(channel))
          readable.insert(channel.value)
          acceptedClient = true
        }
      }
      let now = DispatchTime.now().uptimeNanoseconds
      for client in clients {
        if client.options == nil && now >= client.deadline {
          client.completion = Wire.failed
          continue
        }
        if readable.contains(client.channel.value) { receive(client) }
      }
      try reconcile()
      if clients.isEmpty && (acceptedClient || now >= startupDeadline) { return }
    }
  }

  private func receive(_ client: Client) {
    var byte: UInt8 = 0
    let count = Darwin.read(client.channel.value, &byte, 1)
    if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
    if count == 0 {
      client.completion = Wire.done
    } else if count < 0 || client.options != nil || !(0xA0...0xA1).contains(byte) {
      client.completion = Wire.failed
    } else {
      client.options = Options(keepDisplayOn: byte & 1 != 0)
    }
  }

  private func reconcile() throws {
    while true {
      let active = clients.filter { $0.options != nil && $0.completion == nil }
      if !active.isEmpty && !inhibiting {
        try Session.start(power: power, state: state)
        inhibiting = true
      }
      let wantsDisplay = active.contains { $0.options?.keepDisplayOn == true }
      if wantsDisplay != displaying {
        if wantsDisplay { try controls.keepDisplayOn() } else { try controls.releaseDisplay() }
        displaying = wantsDisplay
      }
      if active.isEmpty && inhibiting {
        try Session.recover(power: power, state: state)
        inhibiting = false
      }
      var lostClient = false
      for client in active where !client.ready {
        if Wire.send(Wire.ready, to: client.channel.value) {
          client.ready = true
        } else {
          client.completion = Wire.done
          lostClient = true
        }
      }
      // A frontend killed during enable may already be gone. Recompute before
      // acknowledging any departures or returning to the blocking poll.
      if lostClient { continue }
      for client in clients {
        if let completion = client.completion {
          _ = Wire.send(completion, to: client.channel.value)
        }
      }
      clients.removeAll { $0.completion != nil }
      return
    }
  }
}
