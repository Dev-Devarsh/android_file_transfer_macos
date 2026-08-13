import FlutterMacOS

/// Single owner of the EventChannel sink (`app.filebridge/events`). Device
/// monitoring and (later) transfer progress push tagged maps through `send`.
/// Events are always delivered on the main thread, as Flutter requires.
final class FileBridgeEvents: NSObject, FlutterStreamHandler {
    static let shared = FileBridgeEvents()

    /// Whether the USB/MTP monitor is the active device source (set by
    /// setTransport). Defaults to true since MTP is the default transport. When
    /// false the wireless (FTP) transport is active and emits from Dart.
    static var activeIsMtp = true

    private let lock = NSLock()
    private var sink: FlutterEventSink?

    func onListen(withArguments arguments: Any?,
                  eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        lock.lock()
        sink = events
        lock.unlock()
        // Push the current device snapshot immediately, so a subscribe that
        // races the first emit still gets the device. Only MTP has a native
        // monitor; the wireless transport re-announces from Dart on connect.
        if Self.activeIsMtp {
            MtpMonitor.shared.emitCurrent()
        }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        lock.lock()
        sink = nil
        lock.unlock()
        return nil
    }

    /// Emit a tagged event map. No-op if Flutter isn't currently listening.
    func send(_ event: [String: Any]) {
        lock.lock()
        let current = sink
        lock.unlock()
        guard let current = current else { return }
        DispatchQueue.main.async { current(event) }
    }
}
