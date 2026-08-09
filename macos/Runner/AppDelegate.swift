import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationDidFinishLaunching(_ notification: Notification) {
    // Default transport is USB/MTP, so begin watching for a connected phone.
    // The wireless (FTP) transport is driven entirely from Dart; nothing native
    // is needed for it. Dart applies the saved transport shortly after launch
    // (stopping this monitor if the user last used wireless).
    MtpMonitor.shared.start()
    Notifier.requestAuthorization()
    super.applicationDidFinishLaunching(notification)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationWillTerminate(_ notification: Notification) {
    MtpMonitor.shared.stop()
    MtpService.shared.close()
    super.applicationWillTerminate(notification)
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
