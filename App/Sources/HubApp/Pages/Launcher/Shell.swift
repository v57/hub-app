//
//  Shell.swift
//  Hub
//
//  Created by Dmitry Kozlov on 19/2/25.
//

#if os(macOS)
import Foundation

extension Data {
  var string: String? { String(data: self, encoding: .utf8) }
}

struct ShellError: Error {
  let code: Int32
}
func hasSh(_ command: String) async -> Bool {
  do {
    try await sh("which \(command)")
    return true
  } catch {
    return false
  }
}
func sh(_ command: String, from: URL = .homeDirectory) async throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/zsh")
  process.arguments = ["-c", "source .zshrc\n" + command.replacingOccurrences(of: "\n", with: ";")]
  process.currentDirectoryURL = from
  try await withCheckedThrowingContinuation { continuation in
    process.terminationHandler = { process in
      if process.terminationStatus == 0 {
        continuation.resume()
      } else {
        print(process.terminationStatus)
        continuation.resume(throwing: ShellError(code: process.terminationStatus))
      }
    }
    do {
      try process.run()
    } catch {
      print(error)
      continuation.resume(throwing: error)
    }
  }
}

extension Process {
  static func execute(_ command: String, from: URL = .homeDirectory) throws -> ExecutingProcess {
    let process = Process()
    let executingProcess = ExecutingProcess(process: process)
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-c", command.replacingOccurrences(of: "\n", with: ";")]
    process.currentDirectoryURL = from
    try process.run()
    return executingProcess
  }
  struct ExecutingProcess {
    let process: Process
    private let stdout: Pipe
    private let stderr: Pipe
    var output: AsyncLineSequence<FileHandle.AsyncBytes> {
      stdout.fileHandleForReading.bytes.lines
    }
    var error: AsyncLineSequence<FileHandle.AsyncBytes> {
      stderr.fileHandleForReading.bytes.lines
    }
    init(process: Process) {
      self.process = process
      stdout = Pipe()
      stderr = Pipe()
      process.standardOutput = stdout
      process.standardError = stderr
    }
    func run() async throws {
      for try await _ in output {}
    }
  }
}

struct GitHub {
  let directory: URL
  func clone(_ project: String) async throws {
    let root = directory.deletingLastPathComponent()
    try await Process.execute("git clone https://github.com/v57/hub-launcher", from: root).run()
  }
  func pull() async throws {
    try await Process.execute("git pull", from: directory).run()
  }
  func checkForUpdates() async -> Bool {
    do {
      let execution = try Process.execute("git fetch origin >/dev/null 2>&1 && git rev-list HEAD..origin/$(git rev-parse --abbrev-ref HEAD) --count", from: directory)
      for try await line in execution.output {
        if let value = Int(line) {
          return value > 0
        }
      }
      return false
    } catch {
      return false
    }
  }
}

#endif
