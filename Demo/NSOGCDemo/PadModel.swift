import Foundation
import NSOGCKit

// Everything here runs on the main queue: it is NSOGCManager's callbackQueue.
final class PadModel: NSObject, ObservableObject, NSOGCManagerDelegate {
  @Published private(set) var lines: [String] = []
  @Published private(set) var bluetoothOn = false
  @Published private(set) var controller: NSOGCController?
  @Published private(set) var state = nsogc_state()
  @Published private(set) var raw = nsogc_raw_input()
  @Published private(set) var reportCount = 0

  private let manager = NSOGCManager.shared
  private var logFile: FileHandle?
  private var started = false

  private static let timestamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
  }()

  func start() {
    guard !started else { return }
    started = true
    openLogFile()
    manager.delegate = self
    manager.logHandler = { [weak self] line in self?.append(line) }
    manager.start()
  }

  func forgetControllers() {
    manager.forgetControllers()
  }

  func setRumble(_ on: Bool) {
    controller?.setRumble(on)
  }

  // MARK: - NSOGCManagerDelegate

  func manager(_ manager: NSOGCManager, didConnect controller: NSOGCController) {
    self.controller = controller
    controller.inputHandler = { [weak self] controller, state in
      guard let self else { return }
      self.state = state
      self.raw = controller.rawInput
      self.reportCount += 1
    }
  }

  func manager(_ manager: NSOGCManager, didDisconnect controller: NSOGCController) {
    if self.controller === controller {
      self.controller = manager.controllers.first
      state = nsogc_state()
    }
  }

  func manager(_ manager: NSOGCManager, bluetoothAvailabilityDidChange available: Bool) {
    bluetoothOn = available
  }

  // MARK: - Log

  private func openLogFile() {
    guard
      let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    else { return }
    let url = documents.appendingPathComponent("nsogc.log")
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    logFile = try? FileHandle(forWritingTo: url)
    _ = try? logFile?.seekToEnd()
    append("---- session \(Date())")
  }

  private func append(_ line: String) {
    let text = "\(Self.timestamp.string(from: Date())) \(line)"
    lines.append(text)
    if lines.count > 400 { lines.removeFirst(lines.count - 400) }
    if let data = (text + "\n").data(using: .utf8) {
      try? logFile?.write(contentsOf: data)
    }
  }
}
