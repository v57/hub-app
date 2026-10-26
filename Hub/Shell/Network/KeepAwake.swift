//
//  KeepAwake.swift
//  Hub
//
//  Keep this Mac awake while it shares its internet, so it answers when its devices are away: a power assertion
//  against idle sleep, held while the setting is on and some hub's network uses this Mac's internet. A closed lid
//  still sleeps the Mac unless it's on power with a display attached, as macOS decides.
//

#if os(macOS)
import Foundation
import IOKit.pwr_mgt

@MainActor @Observable
final class KeepAwake {
  static let main = KeepAwake()

  /// Keep this Mac awake while sharing
  var isOn: Bool = UserDefaults.standard.bool(forKey: "network.keepAwake") {
    didSet {
      UserDefaults.standard.set(isOn, forKey: "network.keepAwake")
      update()
    }
  }
  /// Whether this Mac shares its internet now
  private var isSharing = false
  private var assertion: IOPMAssertionID?

  /// Holds the assertion while sharing with the setting on, and lets it go otherwise
  func update(sharing: Bool? = nil) {
    if let sharing { isSharing = sharing }
    let wanted = isOn && isSharing
    if wanted, assertion == nil {
      var id = IOPMAssertionID(0)
      let reason = "Hub shares this Mac's internet with your devices" as CFString
      if IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &id) == kIOReturnSuccess {
        assertion = id
      }
    } else if !wanted, let id = assertion {
      IOPMAssertionRelease(id)
      assertion = nil
    }
  }

  var isHeld: Bool { assertion != nil }
}
#endif
