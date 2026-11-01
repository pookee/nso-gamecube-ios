// Prints the input of connected NSO GameCube controllers on a Mac, over USB
// and Bluetooth, twice a second.
//
//   swift run nsogc-monitor [--usb-only] [--seconds N]

import Foundation
import NSOGCKit

final class Monitor: NSObject, NSOGCManagerDelegate {
  private var reports: [UUID: Int] = [:]
  private var lastCounts: [UUID: Int] = [:]
  private var lastPrint = Date()

  func manager(_ manager: NSOGCManager, didConnect controller: NSOGCController) {
    print("connected: \(controller.name), player \(controller.playerIndex + 1), "
      + (controller.isWired ? "USB" : "Bluetooth"))
    controller.inputHandler = { [weak self] controller, _ in
      self?.reports[controller.identifier, default: 0] += 1
    }
  }

  func manager(_ manager: NSOGCManager, didDisconnect controller: NSOGCController) {
    print("disconnected: \(controller.name)")
  }

  func printStatus(_ manager: NSOGCManager) {
    let elapsed = Date().timeIntervalSince(lastPrint)
    lastPrint = Date()
    for controller in manager.controllers {
      let state = controller.state
      let count = reports[controller.identifier, default: 0]
      let rate = Double(count - lastCounts[controller.identifier, default: 0]) / max(elapsed, 0.001)
      lastCounts[controller.identifier] = count
      print(
        String(
          format: "P%d %@ %3.0f/s  stick %+.2f %+.2f  c %+.2f %+.2f  L %.2f R %.2f  %@",
          controller.playerIndex + 1, controller.isWired ? "USB" : "BLE", rate,
          state.stick_x, state.stick_y, state.cstick_x, state.cstick_y,
          state.trigger_l, state.trigger_r, Self.buttonNames(state.buttons)))
    }
  }

  private static let names: [(String, nsogc_button)] = [
    ("A", NSOGC_BUTTON_A), ("B", NSOGC_BUTTON_B), ("X", NSOGC_BUTTON_X), ("Y", NSOGC_BUTTON_Y),
    ("Z", NSOGC_BUTTON_Z), ("L", NSOGC_BUTTON_L), ("R", NSOGC_BUTTON_R), ("ZL", NSOGC_BUTTON_ZL),
    ("Start", NSOGC_BUTTON_START), ("Up", NSOGC_BUTTON_DPAD_UP), ("Down", NSOGC_BUTTON_DPAD_DOWN),
    ("Left", NSOGC_BUTTON_DPAD_LEFT), ("Right", NSOGC_BUTTON_DPAD_RIGHT),
    ("Home", NSOGC_BUTTON_HOME), ("Capture", NSOGC_BUTTON_CAPTURE), ("GL", NSOGC_BUTTON_GL),
    ("GR", NSOGC_BUTTON_GR), ("Chat", NSOGC_BUTTON_CHAT),
  ]

  private static func buttonNames(_ buttons: UInt32) -> String {
    let pressed = names.filter { buttons & $0.1.rawValue != 0 }.map(\.0)
    return pressed.isEmpty ? "-" : pressed.joined(separator: " ")
  }
}

let arguments = CommandLine.arguments
let manager = NSOGCManager.shared
manager.usesBluetooth = !arguments.contains("--usb-only")
manager.logHandler = { print("nsogc:", $0) }
let monitor = Monitor()
manager.delegate = monitor
manager.start()

Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in monitor.printStatus(manager) }
if let index = arguments.firstIndex(of: "--seconds"), index + 1 < arguments.count,
  let seconds = Double(arguments[index + 1])
{
  DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
    manager.stop()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
  }
}
RunLoop.main.run()
