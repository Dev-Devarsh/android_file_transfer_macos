import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Window sizing (spec: min 900x600, default 1200x750).
    self.minSize = NSSize(width: 900, height: 600)
    self.setContentSize(NSSize(width: 1200, height: 750))
    self.center()

    setUpChannels(with: flutterViewController)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  private func setUpChannels(with controller: FlutterViewController) {
    let messenger = controller.engine.binaryMessenger

    let commands = FlutterMethodChannel(
      name: "app.filebridge/commands",
      binaryMessenger: messenger
    )
    commands.setMethodCallHandler { call, result in
      Self.handle(call, result: result)
    }

    let events = FlutterEventChannel(
      name: "app.filebridge/events",
      binaryMessenger: messenger
    )
    events.setStreamHandler(FileBridgeEvents.shared)
  }

  /// Routes a MethodChannel call. The USB (MTP) transport is served here; the
  /// wireless (FTP) transport lives entirely in Dart, so those commands never
  /// reach the native side. Work runs off the main thread and the reply is
  /// delivered back on the main thread.
  private static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {

    case "setTransport":
      let a = call.arguments as? [String: Any] ?? [:]
      let transport = a["transport"] as? String ?? "mtp"
      FileBridgeEvents.activeIsMtp = (transport == "mtp")
      NSLog("[Transport] setTransport -> \(transport)")
      if transport == "mtp" {
        MtpMonitor.shared.start()   // its refresh emits fresh state immediately
      } else {
        // Wireless (or none): native device monitoring is idle.
        MtpMonitor.shared.stop()
        MtpService.shared.close()
      }
      result(nil)

    case "listDirectory":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
        result(FlutterError(code: "BAD_ARGS",
                            message: "listDirectory requires a path", details: nil))
        return
      }
      runOffMain(result) { try MtpService.shared.listDirectoryPath(path) }

    case "pushFile":
      let a = call.arguments as? [String: Any] ?? [:]
      guard let localPath = a["localPath"] as? String,
            let remotePath = a["remotePath"] as? String,
            let transferId = a["transferId"] as? String else {
        result(FlutterError(code: "BAD_ARGS", message: "pushFile args", details: nil)); return
      }
      MtpService.shared.pushPath(localPath: localPath, remotePath: remotePath, transferId: transferId)
      result(nil)

    case "pullFile":
      let a = call.arguments as? [String: Any] ?? [:]
      guard let remotePath = a["remotePath"] as? String,
            let localPath = a["localPath"] as? String,
            let transferId = a["transferId"] as? String else {
        result(FlutterError(code: "BAD_ARGS", message: "pullFile args", details: nil)); return
      }
      MtpService.shared.pullPath(remotePath: remotePath, localPath: localPath, transferId: transferId)
      result(nil)

    case "cancelTransfer":
      let a = call.arguments as? [String: Any] ?? [:]
      guard let transferId = a["transferId"] as? String else {
        result(FlutterError(code: "BAD_ARGS", message: "cancelTransfer args", details: nil)); return
      }
      MtpService.shared.cancel(transferId: transferId)
      result(nil)

    case "deleteRemote":
      let a = call.arguments as? [String: Any] ?? [:]
      guard let path = a["path"] as? String else {
        result(FlutterError(code: "BAD_ARGS", message: "deleteRemote args", details: nil)); return
      }
      runOffMain(result) { try MtpService.shared.deletePath(path); return nil }

    case "makeRemoteDir":
      let a = call.arguments as? [String: Any] ?? [:]
      guard let path = a["path"] as? String else {
        result(FlutterError(code: "BAD_ARGS", message: "makeRemoteDir args", details: nil)); return
      }
      runOffMain(result) { try MtpService.shared.makeDirPath(path); return nil }

    case "remoteFreeSpace":
      let a = call.arguments as? [String: Any] ?? [:]
      guard let path = a["path"] as? String else {
        result(FlutterError(code: "BAD_ARGS", message: "remoteFreeSpace args", details: nil)); return
      }
      runOffMain(result) { try MtpService.shared.freeSpacePath(path) }

    case "showNotification":
      let a = call.arguments as? [String: Any] ?? [:]
      Notifier.show(title: a["title"] as? String ?? "",
                    body: a["body"] as? String ?? "")
      result(nil)

    case "getPref":
      let a = call.arguments as? [String: Any] ?? [:]
      guard let key = a["key"] as? String else {
        result(FlutterError(code: "BAD_ARGS", message: "getPref args", details: nil)); return
      }
      result(UserDefaults.standard.object(forKey: key))

    case "setPref":
      let a = call.arguments as? [String: Any] ?? [:]
      guard let key = a["key"] as? String else {
        result(FlutterError(code: "BAD_ARGS", message: "setPref args", details: nil)); return
      }
      if let value = a["value"] {
        UserDefaults.standard.set(value, forKey: key)
      } else {
        UserDefaults.standard.removeObject(forKey: key)
      }
      result(nil)

    case "chooseSaveDirectory":
      // Runs on the main thread (method handler is on main) — required for AppKit.
      let panel = NSOpenPanel()
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      panel.allowsMultipleSelection = false
      panel.prompt = "Save Here"
      panel.message = "Choose where to copy the file(s)"
      let response = panel.runModal()
      result(response == .OK ? panel.url?.path : nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Runs a throwing MTP operation off the main thread and delivers the value
  /// (or a FlutterError) back on the main thread.
  private static func runOffMain(_ result: @escaping FlutterResult,
                                 _ work: @escaping () throws -> Any?) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let value = try work()
        DispatchQueue.main.async { result(value) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "IO_ERROR",
                              message: error.localizedDescription,
                              details: nil))
        }
      }
    }
  }
}
