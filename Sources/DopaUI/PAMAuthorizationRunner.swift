import CDopa
import Darwin
import Foundation

/// Tries the machine's configured `sudo` PAM stack on a real controlling PTY.
/// Native mechanisms such as Touch ID and Apple Watch keep their own trusted
/// UI. Dopa never reads an administrator password itself. A PAM stack that
/// requires textual terminal conversation is left to an explicit Terminal
/// invocation instead of being bypassed through another authorization path.
enum PAMAuthorizationRunner {
  private enum PAMResult {
    case completed(DaemonInstaller.CommandResult)
    case textInputRequired
  }

  private static let maximumTranscriptBytes = 64 * 1024
  private static let authenticationTimeout: Duration = .seconds(300)
  private static let commandTimeout: Duration = .seconds(60)

  static func run(_ command: String) async throws -> DaemonInstaller.CommandResult {
    switch await runPAM(command) {
    case .completed(let result): return result
    case .textInputRequired:
      return .init(
        status: 1,
        standardError: "このMacのsudo PAM設定はターミナル入力を必要とします。Terminalから同梱のdopa-daemonをsudoで実行してください。")
    }
  }

  private static func runPAM(_ command: String) async -> PAMResult {
    let task: Task<PAMResult, Never> = Task.detached(priority: .userInitiated) {
      let marker = "__DOPA_PAM_TEXT_INPUT_\(UUID().uuidString)__"
      let commandStartedMarker = "__DOPA_PRIVILEGED_COMMAND_\(UUID().uuidString)__"
      let markedCommand = "/usr/bin/printf '%s\\n' '\(commandStartedMarker)'\n\(command)"
      var master: Int32 = -1
      let child = markedCommand.withCString { commandPointer in
        marker.withCString { markerPointer in
          dopa_spawn_pam_sudo(commandPointer, markerPointer, &master)
        }
      }
      guard child > 0, master >= 0 else {
        return .completed(.init(
          status: 1,
          standardError: "PAM認証を開始できません。\n\(String(cString: strerror(errno)))"))
      }

      let markerData = Data(marker.utf8)
      let commandStartedMarkerData = Data(commandStartedMarker.utf8)
      var scanBuffer = Data()
      var transcript = Data()
      let clock = ContinuousClock()
      let authenticationDeadline = clock.now.advanced(by: authenticationTimeout)
      var commandDeadline: ContinuousClock.Instant?
      var status: Int32 = 0

      while true {
        let deadline = commandDeadline ?? authenticationDeadline
        if Task.isCancelled || clock.now >= deadline {
          terminate(child: child, master: master, status: &status)
          return .completed(.init(
            status: 1,
            standardError: Task.isCancelled
              ? "認証がキャンセルされました。"
              : commandDeadline == nil
                ? "認証がタイムアウトしました。" : "dopa-daemonの処理がタイムアウトしました。"))
        }

        var descriptor = pollfd(
          fd: master, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
        let ready = poll(&descriptor, 1, 100)
        if ready > 0, descriptor.revents & Int16(POLLNVAL) != 0 {
          terminate(child: child, master: master, status: &status)
          return .completed(.init(
            status: 1, standardError: "PAM認証の端末が予期せず閉じられました。"))
        }
        if ready > 0, descriptor.revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
          while true {
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(master, &bytes, bytes.count)
            guard count > 0 else {
              if count < 0, errno == EINTR { continue }
              break
            }
            let chunk = Data(bytes.prefix(count))
            appendDiagnostic(chunk, to: &transcript)
            scanBuffer.append(chunk)
            // Do not infer a password prompt from terminal ECHO. Touch ID and
            // Apple Watch PAM modules also disable ECHO while trusted UI is up.
            // Only sudo's unique -p marker proves that textual input is needed.
            if scanBuffer.range(of: markerData) != nil {
              terminate(child: child, master: master, status: &status)
              return .textInputRequired
            }
            if scanBuffer.range(of: commandStartedMarkerData) != nil,
              commandDeadline == nil {
              commandDeadline = clock.now.advanced(by: commandTimeout)
            }
            let retainedCount = max(markerData.count, commandStartedMarkerData.count) - 1
            if scanBuffer.count > retainedCount {
              scanBuffer.removeFirst(scanBuffer.count - retainedCount)
            }
          }
        }

        let waited = waitpid(child, &status, WNOHANG)
        if waited == child { break }
        if waited < 0, errno != EINTR {
          close(master)
          return .completed(.init(
            status: 1, standardError: "PAM認証の終了状態を確認できません。"))
        }
      }

      drain(master, into: &transcript)
      close(master)
      return .completed(.init(
        status: exitStatus(status),
        standardError: sanitizedDiagnostic(
          transcript, markers: [marker, commandStartedMarker])))
    }
    return await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private static func terminate(child: pid_t, master: Int32, status: inout Int32) {
    let foregroundGroup = tcgetpgrp(master)
    var interrupt: UInt8 = 0x03
    _ = Darwin.write(master, &interrupt, 1)
    close(master)
    signalProcessGroup(foregroundGroup, signal: SIGINT)
    if wait(child: child, status: &status, for: .seconds(2)) { return }
    signalProcessGroup(foregroundGroup, signal: SIGTERM)
    _ = kill(child, SIGTERM)
    if wait(child: child, status: &status, for: .seconds(1)) { return }
    signalProcessGroup(foregroundGroup, signal: SIGKILL)
    _ = kill(child, SIGKILL)
    _ = wait(child: child, status: &status, for: .seconds(1))
  }

  private static func signalProcessGroup(_ group: pid_t, signal: Int32) {
    guard group > 0, group != getpgrp() else { return }
    _ = kill(-group, signal)
  }

  private static func wait(
    child: pid_t, status: inout Int32, for duration: Duration
  ) -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: duration)
    repeat {
      let result = waitpid(child, &status, WNOHANG)
      if result == child { return true }
      if result < 0, errno != EINTR { return true }
      usleep(20_000)
    } while clock.now < deadline
    return false
  }

  private static func drain(_ descriptor: Int32, into transcript: inout Data) {
    let oldFlags = fcntl(descriptor, F_GETFL)
    if oldFlags >= 0 { _ = fcntl(descriptor, F_SETFL, oldFlags | O_NONBLOCK) }
    var bytes = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = Darwin.read(descriptor, &bytes, bytes.count)
      guard count > 0 else { return }
      appendDiagnostic(Data(bytes.prefix(count)), to: &transcript)
    }
  }

  private static func appendDiagnostic(_ data: Data, to transcript: inout Data) {
    guard transcript.count < maximumTranscriptBytes else { return }
    transcript.append(data.prefix(maximumTranscriptBytes - transcript.count))
  }

  private static func sanitizedDiagnostic(_ data: Data, markers: [String]) -> String {
    markers.reduce(String(decoding: data, as: UTF8.self)) { value, marker in
      value.replacingOccurrences(of: marker, with: "")
    }.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func exitStatus(_ status: Int32) -> Int32 {
    if status & 0x7F == 0 { return (status >> 8) & 0xFF }
    return 128 + (status & 0x7F)
  }
}
