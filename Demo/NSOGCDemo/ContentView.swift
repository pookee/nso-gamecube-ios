import NSOGCKit
import SwiftUI

struct ContentView: View {
  @ObservedObject var model: PadModel

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 16) {
        status
        if model.controller != nil {
          HStack(spacing: 24) {
            StickView(title: "Stick", x: model.state.stick_x, y: model.state.stick_y)
            StickView(title: "C-stick", x: model.state.cstick_x, y: model.state.cstick_y)
            VStack(spacing: 10) {
              TriggerView(title: "L", value: model.state.trigger_l)
              TriggerView(title: "R", value: model.state.trigger_r)
            }
          }
          ButtonsView(buttons: model.state.buttons)
          Text(rawText)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
          Button("Hold to rumble") {}
            .buttonStyle(.bordered)
            .simultaneousGesture(
              DragGesture(minimumDistance: 0)
                .onChanged { _ in model.setRumble(true) }
                .onEnded { _ in model.setRumble(false) })
        }
        LogView(lines: model.lines)
      }
      .padding()
      .navigationTitle("GC Pad Test")
      .toolbar {
        Button("Forget") { model.forgetControllers() }
      }
    }
  }

  private var status: some View {
    Group {
      if !model.bluetoothOn {
        Label("Bluetooth is off or not allowed", systemImage: "antenna.radiowaves.left.and.right.slash")
      } else if let controller = model.controller {
        Label("\(controller.name), player \(controller.playerIndex + 1)", systemImage: "gamecontroller.fill")
          .foregroundStyle(.green)
      } else {
        Label("Press SYNC on the controller", systemImage: "dot.radiowaves.left.and.right")
      }
    }
    .font(.headline)
  }

  private var rawText: String {
    let raw = model.raw
    return String(
      format: "%d reports  stick %d,%d  c %d,%d  L %d R %d  buttons 0x%06X",
      model.reportCount, raw.stick_x, raw.stick_y, raw.cstick_x, raw.cstick_y,
      raw.trigger_l, raw.trigger_r, raw.buttons)
  }
}

private struct StickView: View {
  let title: String
  let x: Float
  let y: Float

  var body: some View {
    VStack {
      ZStack {
        Circle().stroke(.secondary, lineWidth: 2)
        Circle()
          .fill(.blue)
          .frame(width: 14, height: 14)
          .offset(x: CGFloat(x) * 40, y: CGFloat(-y) * 40)
      }
      .frame(width: 94, height: 94)
      Text(title).font(.caption)
    }
  }
}

private struct TriggerView: View {
  let title: String
  let value: Float

  var body: some View {
    HStack {
      Text(title).font(.caption.bold()).frame(width: 14)
      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          Capsule().fill(.secondary.opacity(0.2))
          Capsule().fill(.orange).frame(width: proxy.size.width * CGFloat(value))
        }
      }
      .frame(width: 90, height: 12)
    }
  }
}

private struct ButtonsView: View {
  let buttons: UInt32

  private static let names: [(String, nsogc_button)] = [
    ("A", NSOGC_BUTTON_A), ("B", NSOGC_BUTTON_B), ("X", NSOGC_BUTTON_X), ("Y", NSOGC_BUTTON_Y),
    ("Z", NSOGC_BUTTON_Z), ("L", NSOGC_BUTTON_L), ("R", NSOGC_BUTTON_R), ("ZL", NSOGC_BUTTON_ZL),
    ("Start", NSOGC_BUTTON_START), ("↑", NSOGC_BUTTON_DPAD_UP), ("↓", NSOGC_BUTTON_DPAD_DOWN),
    ("←", NSOGC_BUTTON_DPAD_LEFT), ("→", NSOGC_BUTTON_DPAD_RIGHT), ("Home", NSOGC_BUTTON_HOME),
    ("Capture", NSOGC_BUTTON_CAPTURE), ("GL", NSOGC_BUTTON_GL), ("GR", NSOGC_BUTTON_GR),
    ("Chat", NSOGC_BUTTON_CHAT),
  ]

  var body: some View {
    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 6) {
      ForEach(Self.names, id: \.0) { name, button in
        let pressed = buttons & button.rawValue != 0
        Text(name)
          .font(.caption.bold())
          .frame(maxWidth: .infinity, minHeight: 26)
          .background(pressed ? Color.green : Color.secondary.opacity(0.15))
          .foregroundStyle(pressed ? Color.white : Color.primary)
          .clipShape(RoundedRectangle(cornerRadius: 6))
      }
    }
  }
}

private struct LogView: View {
  let lines: [String]

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
            Text(line)
              .font(.caption2.monospaced())
              .textSelection(.enabled)
              .id(index)
          }
        }
      }
      .onChange(of: lines.count) { count in
        proxy.scrollTo(count - 1, anchor: .bottom)
      }
    }
  }
}
