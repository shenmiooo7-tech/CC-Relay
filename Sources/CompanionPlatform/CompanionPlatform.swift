import Foundation

/// macOS adapters (processes, launch services, keychain, cookies, login items)
/// will live in this module. The skeleton does not perform any of those actions.
/// Each future adapter calls `SafetyTripwire.assertLiveActionsAllowed()` first.
public enum CompanionPlatformModule {}
