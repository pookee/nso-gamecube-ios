import SwiftUI

@main
struct DemoApp: App {
  @StateObject private var model = PadModel()

  var body: some Scene {
    WindowGroup {
      ContentView(model: model)
        .onAppear { model.start() }
    }
  }
}
