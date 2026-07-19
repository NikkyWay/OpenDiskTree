import Testing

@testable import OpenDiskTreeCore

@Test func safetyStatusWireValuesAreStable() {
  #expect(SafetyStatus.safeToDelete.rawValue == "safe_to_delete")
  #expect(SafetyStatus.doNotTouch.rawValue == "do_not_touch")
}
