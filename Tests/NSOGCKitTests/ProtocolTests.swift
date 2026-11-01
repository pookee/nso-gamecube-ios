import NSOGCKit
import XCTest

final class ProtocolTests: XCTestCase {
  // Packs two 12-bit axes the way the controller does.
  private func packStick(_ x: UInt16, _ y: UInt16) -> [UInt8] {
    [UInt8(x & 0xFF), UInt8((x >> 8) & 0x0F) | UInt8((y & 0x0F) << 4), UInt8(y >> 4)]
  }

  private func nativeReport(
    buttons: (UInt8, UInt8, UInt8) = (0, 0, 0),
    stick: (UInt16, UInt16) = (2048, 2048),
    cStick: (UInt16, UInt16) = (2048, 2048),
    triggers: (UInt8, UInt8) = (34, 34)
  ) -> [UInt8] {
    var report = [UInt8](repeating: 0, count: Int(NSOGC_NATIVE_REPORT_SIZE))
    report[0] = 7
    report[1] = 0x20
    report[2] = buttons.0
    report[3] = buttons.1
    report[4] = buttons.2
    report.replaceSubrange(5..<8, with: packStick(stick.0, stick.1))
    report.replaceSubrange(8..<11, with: packStick(cStick.0, cStick.1))
    report[11] = 0x30
    report[12] = triggers.0
    report[13] = triggers.1
    return report
  }

  private func parse(_ report: [UInt8]) -> (nsogc_report_format, nsogc_raw_input) {
    var raw = nsogc_raw_input()
    let format = report.withUnsafeBufferPointer {
      nsogc_parse_report($0.baseAddress, $0.count, &raw)
    }
    return (format, raw)
  }

  func testNativeReportDecodesButtonsSticksAndTriggers() {
    let report = nativeReport(
      buttons: (0x02 | 0x40, 0x08 | 0x10, 0x01),  // A, Start; D-pad up, L; Home
      stick: (3000, 1000), cStick: (100, 4000), triggers: (200, 34))
    let (format, raw) = parse(report)
    XCTAssertEqual(format, NSOGC_REPORT_NATIVE)
    XCTAssertEqual(raw.counter, 7)
    let expected =
      NSOGC_BUTTON_A.rawValue | NSOGC_BUTTON_START.rawValue | NSOGC_BUTTON_DPAD_UP.rawValue
      | NSOGC_BUTTON_L.rawValue | NSOGC_BUTTON_HOME.rawValue
    XCTAssertEqual(raw.buttons, expected)
    XCTAssertEqual(raw.stick_x, 3000)
    XCTAssertEqual(raw.stick_y, 1000)
    XCTAssertEqual(raw.cstick_x, 100)
    XCTAssertEqual(raw.cstick_y, 4000)
    XCTAssertEqual(raw.trigger_l, 200)
    XCTAssertEqual(raw.trigger_r, 34)
  }

  func testShortNotificationsAreNotInput() {
    let (format, raw) = parse([UInt8](repeating: 0xAA, count: 16))
    XCTAssertEqual(format, NSOGC_REPORT_INVALID)
    XCTAssertEqual(raw.buttons, 0)
  }

  func testProLayoutReportsAreRemapped() {
    var report = [UInt8](repeating: 0, count: 49)
    report[0] = 0x30
    report[3] = 0x08 | 0x20  // A, ZR -> Z
    report[4] = 0x02  // Plus -> Start
    report[5] = 0x02 | 0x40  // D-pad up, L
    report.replaceSubrange(6..<9, with: packStick(2048, 2048))
    report.replaceSubrange(9..<12, with: packStick(2048, 2048))
    let (format, raw) = parse(report)
    XCTAssertEqual(format, NSOGC_REPORT_PRO_FULL)
    let expected =
      NSOGC_BUTTON_A.rawValue | NSOGC_BUTTON_Z.rawValue | NSOGC_BUTTON_START.rawValue
      | NSOGC_BUTTON_DPAD_UP.rawValue | NSOGC_BUTTON_L.rawValue
    XCTAssertEqual(raw.buttons, expected)
  }

  func testNormalizationCentresDeadZoneAndClamps() {
    var calibration = nsogc_calibration()
    nsogc_calibration_default(&calibration)
    var state = nsogc_state()

    var (_, raw) = parse(nativeReport(stick: (2060, 2040)))  // inside the dead zone
    nsogc_normalize(&raw, &calibration, &state)
    XCTAssertEqual(state.stick_x, 0)
    XCTAssertEqual(state.stick_y, 0)
    XCTAssertEqual(state.trigger_l, 0)

    (_, raw) = parse(nativeReport(stick: (4095, 2048), cStick: (2048, 0), triggers: (255, 132)))
    nsogc_normalize(&raw, &calibration, &state)
    XCTAssertEqual(state.stick_x, 1, accuracy: 0.0001)
    XCTAssertEqual(state.stick_y, 0, accuracy: 0.0001)
    XCTAssertEqual(state.cstick_y, -1, accuracy: 0.0001)
    XCTAssertEqual(state.trigger_l, 1, accuracy: 0.0001)
    XCTAssertEqual(state.trigger_r, 0.5, accuracy: 0.01)

    (_, raw) = parse(nativeReport(stick: (4095, 4095)))  // a corner stays on the unit circle
    nsogc_normalize(&raw, &calibration, &state)
    let length = (state.stick_x * state.stick_x + state.stick_y * state.stick_y).squareRoot()
    XCTAssertEqual(length, 1, accuracy: 0.0001)
  }

  private func frame(_ build: (UnsafeMutablePointer<UInt8>) -> Int) -> [UInt8] {
    var buffer = [UInt8](repeating: 0, count: Int(NSOGC_COMMAND_MAX_SIZE))
    let length = buffer.withUnsafeMutableBufferPointer { build($0.baseAddress!) }
    return Array(buffer.prefix(length))
  }

  func testCommandFrames() {
    XCTAssertEqual(
      frame { nsogc_command_spi_read($0, NSOGC_SPI_DEVICE_INFO, 0x40) },
      [0x02, 0x91, 0x01, 0x04, 0x00, 0x08, 0x00, 0x00, 0x40, 0x7E, 0x00, 0x00, 0x00, 0x30, 0x01, 0x00])
    XCTAssertEqual(
      frame { nsogc_command_player_leds($0, nsogc_player_led_mask(1)) },
      [0x09, 0x91, 0x01, 0x07, 0x00, 0x08, 0x00, 0x00, 0x03, 0, 0, 0, 0, 0, 0, 0])
    XCTAssertEqual(
      frame { nsogc_command_default_report($0) },
      [0x03, 0x91, 0x00, 0x0D, 0x00, 0x08, 0x00, 0x00, 0x01, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    XCTAssertEqual(
      frame { nsogc_command_vibration($0, true) },
      [0x0A, 0x91, 0x01, 0x02, 0x00, 0x04, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00])
    XCTAssertEqual(nsogc_player_led_mask(0), 0x01)
    XCTAssertEqual(nsogc_player_led_mask(3), 0x0F)
    XCTAssertEqual(nsogc_player_led_mask(9), 0x0F)
  }

  func testAdvertisementMatching() {
    func matches(_ data: [UInt8]) -> (Bool, UInt16) {
      var product: UInt16 = 0
      let result = data.withUnsafeBufferPointer {
        nsogc_advertisement_matches($0.baseAddress, $0.count, &product)
      }
      return (result, product)
    }
    // Company 0x0553, then vendor 0x057E and product 0x2073.
    XCTAssertEqual(matches([0x53, 0x05, 0x01, 0x7E, 0x05, 0x73, 0x20, 0x00]).0, true)
    XCTAssertEqual(matches([0x53, 0x05, 0x01, 0x7E, 0x05, 0x73, 0x20, 0x00]).1, 0x2073)
    // A Pro Controller 2 (0x2069) is not this controller.
    XCTAssertEqual(matches([0x53, 0x05, 0x01, 0x7E, 0x05, 0x69, 0x20, 0x00]).0, false)
    // Nintendo data without a product ID is a candidate.
    XCTAssertEqual(matches([0x7E, 0x03, 0x01, 0x02]).0, true)
    // Another company is not.
    XCTAssertEqual(matches([0x4C, 0x00, 0x7E, 0x05, 0x73, 0x20]).0, false)
  }

  // The Swift names the README documents. Creating the manager does not touch
  // Bluetooth; only start does.
  func testSwiftAPINames() {
    let manager = NSOGCManager.shared
    XCTAssertFalse(manager.isRunning)
    XCTAssertFalse(manager.isScanning)
    XCTAssertEqual(manager.maximumControllers, 4)
    XCTAssertFalse(manager.deliversInputOnBluetoothQueue)
    XCTAssertTrue(manager.controllers.isEmpty)
    let disconnect: (NSOGCController) -> Void = manager.disconnect
    _ = disconnect
    _ = manager.hasRememberedControllers
  }
}
