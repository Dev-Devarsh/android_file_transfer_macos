import Foundation
import IOKit
import IOKit.usb

/// Detects the MTP device coming and going. USB attach/detach events (and a slow
/// poll fallback) trigger a re-detect. On detach we drop the (now stale) libmtp
/// handle so the next detect cleanly reopens or reports the device gone.
final class MtpMonitor {
    static let shared = MtpMonitor()
    private init() {}

    private let queue = DispatchQueue(label: "app.filebridge.mtpmonitor")
    private var notifyPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var pollTimer: DispatchSourceTimer?
    private var debounce: DispatchWorkItem?

    private var running = false
    private var lastDevices: [[String: Any]] = []
    private var emptyStreak = 0

    func start() {
        queue.async { [weak self] in
            guard let self = self, !self.running else { return }
            self.running = true
            self.setUpUSBNotifications()
            self.startPolling()
            self.refresh(dropHandle: false)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.pollTimer?.cancel(); self.pollTimer = nil
            for it in self.iterators { IOObjectRelease(it) }
            self.iterators.removeAll()
            if let port = self.notifyPort { IONotificationPortDestroy(port) }
            self.notifyPort = nil
            self.running = false
        }
    }

    func emitCurrent() {
        queue.async { [weak self] in
            guard let self = self else { return }
            FileBridgeEvents.shared.send(["type": "devicesChanged", "devices": self.lastDevices])
        }
    }

    // MARK: USB hot-plug

    private func setUpUSBNotifications() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, queue)
        notifyPort = port
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // Attach: just re-detect. Detach: drop the stale handle, then re-detect.
        let attachCb: IOServiceMatchingCallback = { context, iterator in
            drain(iterator)
            guard let context = context else { return }
            Unmanaged<MtpMonitor>.fromOpaque(context).takeUnretainedValue()
                .scheduleRefresh(dropHandle: false)
        }
        let detachCb: IOServiceMatchingCallback = { context, iterator in
            drain(iterator)
            guard let context = context else { return }
            Unmanaged<MtpMonitor>.fromOpaque(context).takeUnretainedValue()
                .scheduleRefresh(dropHandle: true)
        }

        for className in ["IOUSBHostDevice", "IOUSBDevice"] {
            add(port, kIOFirstMatchNotification, className, attachCb, refcon)
            add(port, kIOTerminatedNotification, className, detachCb, refcon)
        }
    }

    private func add(_ port: IONotificationPortRef, _ type: String, _ className: String,
                     _ cb: @escaping IOServiceMatchingCallback, _ refcon: UnsafeMutableRawPointer) {
        var iterator: io_iterator_t = 0
        let kr = IOServiceAddMatchingNotification(port, type, IOServiceMatching(className), cb, refcon, &iterator)
        guard kr == KERN_SUCCESS else { return }
        drain(iterator)   // arm
        iterators.append(iterator)
    }

    // MARK: Polling + refresh

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in self?.refresh(dropHandle: false) }
        timer.resume()
        pollTimer = timer
    }

    private func scheduleRefresh(dropHandle: Bool) {
        debounce?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.refresh(dropHandle: dropHandle) }
        debounce = item
        queue.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    private func refresh(dropHandle: Bool) {
        if dropHandle { MtpService.shared.dropHandle() }
        let devices = MtpService.shared.detectDevices()

        // Hysteresis: MTP occasionally fails to open for a single poll. Don't
        // drop a known device on one empty read — require two in a row (or an
        // explicit detach) before reporting it gone, to avoid UI flicker.
        if devices.isEmpty {
            emptyStreak += 1
            if !dropHandle && emptyStreak < 2 && !lastDevices.isEmpty {
                FileBridgeEvents.shared.send(["type": "devicesChanged", "devices": lastDevices])
                return
            }
        } else {
            emptyStreak = 0
        }

        lastDevices = devices
        // Emit every poll (not de-duped): the Dart side de-dupes, and always
        // sending makes delivery resilient to the EventChannel subscribe race.
        FileBridgeEvents.shared.send(["type": "devicesChanged", "devices": devices])
    }
}

/// Drain an IOKit iterator to (re)arm its notification.
private func drain(_ iterator: io_iterator_t) {
    while case let obj = IOIteratorNext(iterator), obj != 0 {
        IOObjectRelease(obj)
    }
}
