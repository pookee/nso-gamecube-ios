# nso-gamecube-ios

The Nintendo Switch Online GameCube controller made for the Switch 2 (vendor
`0x057E`, product `0x2073`) on iPhone, iPad and Mac, over Bluetooth LE.

iOS has no driver for this controller: it speaks Nintendo's own BLE protocol,
so the system never shows it as a game controller. NSOGCKit connects it from
inside an app with CoreBluetooth and hands the app its input.

## Status

Tested on an iPhone running iOS 27.2 with a real controller:

- found while in SYNC mode, connected and set up, then remembered;
- buttons, both sticks and the analog triggers with their end-of-travel clicks,
  the player LEDs, and a once-a-second LED write that keeps the link up (without
  it the controller drops the connection after about 40 seconds);
- used as player one in [SunPad](https://github.com/chrissotraidis/sunpad)
  (Super Mario Sunshine), which takes its rumble too.

Not verified yet: rumble on the controller itself, waking a remembered
controller with a button press instead of SYNC, two controllers at once.

On iOS the controller sends 20 to 30 reports a second: iOS sets the Bluetooth
connection interval and an app cannot change it. That is enough for a 30 fps
game.

## Limits

An iOS app cannot create a controller for the whole system (there is no
equivalent of ViGEm or uinput), so the controller works in the apps that
include this library, not in every game.

## Use

Swift Package Manager: add this repository (or its folder) and the `NSOGCKit`
product. An Objective-C or C++ app can instead copy `Sources/NSOGCKit` with
`include/` flattened into one folder (SunPad does this in `apple/ios/NSOGC`).

The app's Info.plist needs `NSBluetoothAlwaysUsageDescription`.

```swift
import NSOGCKit

let manager = NSOGCManager.shared
manager.delegate = self  // manager(_:didConnect:), manager(_:didDisconnect:)
manager.start()

func manager(_ manager: NSOGCManager, didConnect controller: NSOGCController) {
  controller.inputHandler = { controller, state in
    // state.stick_x / stick_y and cstick_x / cstick_y in -1...1 (up and right
    // positive), trigger_l / trigger_r in 0...1, state.buttons as nsogc_button bits
  }
}
```

Press SYNC on the controller while the app is scanning. Callbacks arrive on
`callbackQueue` (main by default); `logHandler` gets one line per setup step,
which is the first thing to read when a controller does not connect.

## How it connects

Observed on the device (CoreBluetooth hides ATT handles, so characteristics are
picked by UUID and by their order in the Nintendo service):

| Step | What |
|---|---|
| Find | manufacturer data with company `0x0553`, vendor `0x057E` and product `0x2073`; the GAP name is `DeviceName` |
| Enable | write `01 00` to `00C5AF5D-1964-4E30-8F51-1956F96BD282` in the control service `…BD280` (it rejects anything but two bytes) |
| Subscribe | every notifying characteristic of the Nintendo service `AB7DE9BE-89FE-49AD-828F-118F09DF7FD0` |
| Commands | on `649D4AC9-8EB7-4E6C-AF44-1EA54FE5F005`, the second write-without-response characteristic: read the device information block (SPI `0x13000`), set the default report, set the player LEDs; responses come back on `C765A961-D9D8-4D36-A20A-5315B111836A` |
| Input | 63-byte reports in the GameCube layout on `8261CBA1-9435-420C-84D6-F0C75A2C8E4D`; `…7FD2` starts with another layout and stops after the default report command |

The report layout and every command frame are in
[`nsogc_protocol.h`](Sources/NSOGCKit/include/nsogc_protocol.h), plain C with
unit tests (`swift test`).

## Test app

`Demo/` shows a connected controller live and writes its log to
`Documents/nsogc.log` (visible in the Files app):

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
plus the measurements above. The default stick ranges come from that app's
calibration defaults.

## License

MIT, see [LICENSE](LICENSE).
