# nso-gamecube-ios

Use the Nintendo Switch Online GameCube controller made for the Switch 2
(vendor `0x057E`, product `0x2073`) in your own iPhone, iPad or Mac app, over
Bluetooth LE.

iOS has no driver for this controller: it speaks Nintendo's own BLE protocol,
so the system never shows it as a game controller and `GCController` never
sees it. NSOGCKit connects it from inside your app with CoreBluetooth, sets it
up and hands you its input, normalized and ready for a game.

## Status

Tested on an iPhone running iOS 27.2 with a real controller, and used to play
a game on it:

- found while in SYNC mode, connected and set up, then remembered and
  reconnected when it advertises again;
- buttons, both sticks, the analog triggers with their end-of-travel clicks,
  and the player LEDs;
- a player-LED write once a second keeps the link up (without one the
  controller drops the connection after about 40 seconds).

Not verified yet: rumble on the controller itself, waking a remembered
controller with a button press instead of SYNC, two controllers at once.

On iOS the controller sends 20 to 30 reports a second: iOS sets the Bluetooth
connection interval and an app cannot change it. That is enough for a 30 or
60 fps game.

## Limits

An iOS app cannot create a controller for the whole system (there is no
equivalent of ViGEm or uinput), so the controller works in the apps that
include this library, not in every game on the phone.

## Add it to an app

Swift Package Manager: add this repository and the `NSOGCKit` product. An
Objective-C or C++ project without packages can instead copy
`Sources/NSOGCKit` with `include/` flattened into one folder: every include is
a plain quoted include.

The app's Info.plist needs `NSBluetoothAlwaysUsageDescription`. The first
`start` shows the Bluetooth permission prompt.

```swift
import NSOGCKit

final class Pads: NSObject, NSOGCManagerDelegate {
  func start() {
    let manager = NSOGCManager.shared
    manager.delegate = self
    manager.logHandler = { print("nsogc", $0) }  // one line per setup step
    manager.start()
  }

  func manager(_ manager: NSOGCManager, didConnect controller: NSOGCController) {
    controller.inputHandler = { controller, state in
      // state.stick_x / stick_y, cstick_x / cstick_y: -1...1, up and right positive
      // state.trigger_l / trigger_r: 0...1
      // state.buttons: nsogc_button bits, e.g. NSOGC_BUTTON_A.rawValue
    }
  }

  func manager(_ manager: NSOGCManager, didDisconnect controller: NSOGCController) {}
}
```

Then press SYNC on the controller. Once set up it is remembered, and a later
`start` reconnects it whenever it is in range and advertising.

| API | What it does |
|---|---|
| `start()` / `stop()` | turn Bluetooth on and look for controllers / disconnect everything and stop |
| `controllers` | connected controllers in player order (also the player LEDs) |
| `maximumControllers` | stop scanning once this many are connected (4 by default) |
| `isScanning`, `hasRememberedControllers` | for a status line in your UI |
| `disconnect(_:)`, `forgetControllers()` | drop one controller; forget the remembered ones |
| `controller.setRumble(_:)` | rumble on or off |
| `controller.calibration` | replace the default stick ranges, dead zone and trigger travel |
| `controller.rawInput` | the values as the controller sent them |

### For games: lowest latency

By default input handlers run on `callbackQueue` (the main queue), and a
report that arrives while the previous one is still queued replaces it. A game
that keeps its input state behind a lock can skip that hop:

```swift
manager.deliversInputOnBluetoothQueue = true  // before start()
controller.inputHandler = { _, state in
  gameInput.store(state)  // thread-safe, fast
  feedTheGameNow()        // don't wait for a fixed polling tick
}
```

The Bluetooth queue runs at user-interactive priority. If the game reads input
from a timer, a timer on its own queue (not the main one) and a push on every
report both cut the delay between a press and the game seeing it.

## How it connects

Observed on the device. CoreBluetooth hides ATT handles, so characteristics are
picked by UUID and by their order in the Nintendo service:

| Step | What |
|---|---|
| Find | manufacturer data with company `0x0553`, vendor `0x057E` and product `0x2073`; the GAP name is `DeviceName` |
| Enable | write `01 00` to `00C5AF5D-1964-4E30-8F51-1956F96BD282` in the control service `…BD280` (it rejects anything but two bytes) |
| Subscribe | every notifying characteristic of the Nintendo service `AB7DE9BE-89FE-49AD-828F-118F09DF7FD0` |
| Commands | on `649D4AC9-8EB7-4E6C-AF44-1EA54FE5F005`, the second write-without-response characteristic: read the device information block (SPI `0x13000`), set the default report, set the player LEDs; responses come back on `C765A961-D9D8-4D36-A20A-5315B111836A` |
| Input | 63-byte reports in the GameCube layout on `8261CBA1-9435-420C-84D6-F0C75A2C8E4D`; `…7FD2` starts with another layout and stops after the default report command |
| Keep alive | the player-LED command again, once a second |

The report layout and every command frame are in
[`nsogc_protocol.h`](Sources/NSOGCKit/include/nsogc_protocol.h): plain C with
no platform dependency and unit tests (`swift test`).

## Test app

`Demo/` shows a connected controller live and writes its log to
`Documents/nsogc.log`, visible in the Files app:

```sh
cd Demo && xcodegen generate && open NSOGCDemo.xcodeproj
```

Set your team and a bundle ID you own, then run it on a device: the iOS
Simulator has no Bluetooth.

## Credits

Written from the protocol as documented and measured, without copying code:
the BLE protocol guide of the
[NSO GameCube Controller Pairing App](https://github.com/RyanCopley/NSO-GameCube-Controller-Pairing-App),
which builds on [BlueRetro](https://github.com/darthcloud/BlueRetro) and
[ndeadly's Switch 2 research](https://github.com/ndeadly/switch2_input_viewer),
plus the measurements above. The default stick ranges are that app's
calibration defaults.

## License

MIT, see [LICENSE](LICENSE).
