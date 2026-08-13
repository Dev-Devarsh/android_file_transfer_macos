import Foundation

/// Swift face of the MTP layer. Every call to `MtpBridge` (libmtp) is serialized
/// onto one queue because MTP is single-channel per device — you cannot browse
/// and transfer, or run two transfers, at the same time. Transfers emit progress
/// and completion through the EventChannel, matching the shapes the Dart side
/// already understands.
final class MtpService {
    static let shared = MtpService()
    private init() {}

    private let bridge = MtpBridge()
    private let queue = DispatchQueue(label: "app.filebridge.mtp")   // serial
    private let cancelLock = NSLock()
    private var cancelled = Set<String>()

    static var rootParent: UInt32 { MtpBridge.rootParent }

    // MARK: - Device lifecycle / detection

    /// The connected device as a single-element list (or empty). Opens the
    /// device if not already open.
    func detectDevices() -> [[String: Any]] {
        queue.sync {
            if !bridge.isOpen {
                do {
                    try bridge.openFirstDevice()
                } catch {
                    return []
                }
            }
            let info = bridge.deviceInfo()
            return [[
                "serial": info["serial"] ?? "",
                "model": info["model"] ?? "MTP device",
                "state": "device",
            ]]
        }
    }

    /// On a USB detach the open handle may be stale — drop it so the next detect
    /// reopens (or reports the device gone).
    func dropHandle() {
        queue.sync { bridge.closeDevice() }
    }

    func close() {
        queue.sync { bridge.closeDevice() }
    }

    // MARK: - Browse

    func storages() throws -> [[String: Any]] {
        try queue.sync {
            try ensureOpen()
            return bridge.storages()
        }
    }

    func listFolder(storageId: UInt32, parentId: UInt32) throws -> [[String: Any]] {
        try queue.sync {
            try ensureOpen()
            return try bridge.listFolder(inStorage: storageId, parent: parentId)
        }
    }

    func freeSpace(storageId: UInt32) throws -> Int {
        try queue.sync {
            try ensureOpen()
            let all = bridge.storages()
            for s in all where (s["storageId"] as? NSNumber)?.uint32Value == storageId {
                return (s["freeBytes"] as? NSNumber)?.intValue ?? 0
            }
            return (all.first?["freeBytes"] as? NSNumber)?.intValue ?? 0
        }
    }

    func createFolder(storageId: UInt32, parentId: UInt32, name: String) throws -> UInt32 {
        try queue.sync {
            try ensureOpen()
            var err: NSError?
            let id = bridge.createFolder(name, storage: storageId, parent: parentId, error: &err)
            if let err = err { throw err }
            return id
        }
    }

    func delete(storageId: UInt32, objectId: UInt32, isDir: Bool) throws {
        try queue.sync {
            try ensureOpen()
            try deleteRecursive(storageId: storageId, objectId: objectId, isDir: isDir)
        }
    }

    private func deleteRecursive(storageId: UInt32, objectId: UInt32, isDir: Bool) throws {
        if isDir {
            let children = (try? bridge.listFolder(inStorage: storageId, parent: objectId)) ?? []
            for child in children {
                guard let cid = (child["objectId"] as? NSNumber)?.uint32Value else { continue }
                let cdir = (child["isDir"] as? NSNumber)?.boolValue ?? false
                try deleteRecursive(storageId: storageId, objectId: cid, isDir: cdir)
            }
        }
        try bridge.deleteObject(objectId)
    }

    // MARK: - Transfers (serialized; emit events)

    func pushFile(storageId: UInt32, parentId: UInt32, localPath: String,
                  name: String, transferId: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            do { try self.ensureOpen() }
            catch { self.emitDone(transferId, success: false, error: error.localizedDescription); return }

            let total = self.localSize(localPath)
            let progress = self.makeProgress(transferId, fallbackTotal: total)
            do {
                var err: NSError?
                _ = self.bridge.sendFile(localPath, storage: storageId, parent: parentId,
                                         name: name, size: UInt64(total), progress: progress, error: &err)
                if let err = err { throw err }
                self.emitProgress(transferId, done: total, total: total, speed: 0)
                self.emitDone(transferId, success: true, error: nil)
            } catch {
                self.finishError(transferId, error: error)
            }
        }
    }

    func pullFile(objectId: UInt32, localPath: String, sizeBytes: Int, transferId: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            do { try self.ensureOpen() }
            catch { self.emitDone(transferId, success: false, error: error.localizedDescription); return }

            let progress = self.makeProgress(transferId, fallbackTotal: sizeBytes)
            do {
                try self.bridge.getObject(objectId, toPath: localPath, progress: progress)
                self.emitDone(transferId, success: true, error: nil)
            } catch {
                // A killed pull leaves a partial local file — remove it.
                try? FileManager.default.removeItem(atPath: localPath)
                self.finishError(transferId, error: error)
            }
        }
    }

    func cancel(transferId: String) {
        cancelLock.lock(); cancelled.insert(transferId); cancelLock.unlock()
    }

    // MARK: - Path-based API (the shared command contract, so the Dart/UI layer
    // is transport-agnostic). MTP is handle-based, so each path is resolved by
    // walking folders from the first storage's root. Root path is "/".

    func listDirectoryPath(_ path: String) throws -> [[String: Any]] {
        try queue.sync {
            try ensureOpen()
            let (sid, folderId) = try resolveFolderLocked(path)
            let children = try bridge.listFolder(inStorage: sid, parent: folderId)
            return children.map { c in
                [
                    "name": (c["name"] as? String) ?? "",
                    "isDir": (c["isDir"] as? NSNumber)?.boolValue ?? false,
                    "sizeBytes": (c["sizeBytes"] as? NSNumber)?.intValue ?? 0,
                    "modifiedEpoch": (c["modifiedEpoch"] as? NSNumber)?.intValue ?? 0,
                    "isSymlink": false,
                ]
            }
        }
    }

    func freeSpacePath(_ path: String) throws -> Int {
        try queue.sync {
            try ensureOpen()
            let sid = try firstStorageIdLocked()
            for s in bridge.storages()
            where (s["storageId"] as? NSNumber)?.uint32Value == sid {
                return (s["freeBytes"] as? NSNumber)?.intValue ?? 0
            }
            return 0
        }
    }

    func makeDirPath(_ path: String) throws {
        try queue.sync {
            try ensureOpen()
            let sid = try firstStorageIdLocked()
            var parent = MtpBridge.rootParent
            for seg in Self.pathSegments(path) {
                let children = try bridge.listFolder(inStorage: sid, parent: parent)
                if let match = children.first(where: {
                    ($0["name"] as? String) == seg
                        && (($0["isDir"] as? NSNumber)?.boolValue ?? false)
                }), let oid = (match["objectId"] as? NSNumber)?.uint32Value {
                    parent = oid
                } else {
                    var err: NSError?
                    let newId = bridge.createFolder(seg, storage: sid, parent: parent, error: &err)
                    if let err = err { throw err }
                    parent = newId
                }
            }
        }
    }

    func deletePath(_ path: String) throws {
        try queue.sync {
            try ensureOpen()
            let (sid, oid, isDir, _) = try resolveEntryLocked(path)
            try deleteRecursive(storageId: sid, objectId: oid, isDir: isDir)
        }
    }

    func pushPath(localPath: String, remotePath: String, transferId: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.ensureOpen()
                let segs = Self.pathSegments(remotePath)
                guard let name = segs.last else {
                    throw NSError(domain: "mtp", code: 10,
                                  userInfo: [NSLocalizedDescriptionKey: "Bad remote path"])
                }
                let parentPath = "/" + segs.dropLast().joined(separator: "/")
                let (sid, parentId) = try self.resolveFolderLocked(parentPath)
                // Delegate to the handle-based transfer (re-enqueues on the queue).
                self.pushFile(storageId: sid, parentId: parentId,
                              localPath: localPath, name: name, transferId: transferId)
            } catch {
                self.emitDone(transferId, success: false, error: error.localizedDescription)
            }
        }
    }

    func pullPath(remotePath: String, localPath: String, transferId: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.ensureOpen()
                let (_, oid, isDir, size) = try self.resolveEntryLocked(remotePath)
                if isDir {
                    throw NSError(domain: "mtp", code: 11,
                                  userInfo: [NSLocalizedDescriptionKey: "Cannot copy a folder"])
                }
                self.pullFile(objectId: oid, localPath: localPath,
                              sizeBytes: size, transferId: transferId)
            } catch {
                self.emitDone(transferId, success: false, error: error.localizedDescription)
            }
        }
    }

    // MARK: - Path resolution (must be called on `queue`, device open)

    static func pathSegments(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    private func firstStorageIdLocked() throws -> UInt32 {
        guard let first = bridge.storages().first,
              let sid = (first["storageId"] as? NSNumber)?.uint32Value else {
            throw NSError(domain: "mtp", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "No MTP storage found"])
        }
        return sid
    }

    private func resolveFolderLocked(_ path: String) throws -> (UInt32, UInt32) {
        let sid = try firstStorageIdLocked()
        var parent = MtpBridge.rootParent
        for seg in Self.pathSegments(path) {
            let children = try bridge.listFolder(inStorage: sid, parent: parent)
            guard let match = children.first(where: {
                ($0["name"] as? String) == seg
                    && (($0["isDir"] as? NSNumber)?.boolValue ?? false)
            }), let oid = (match["objectId"] as? NSNumber)?.uint32Value else {
                throw NSError(domain: "mtp", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "Folder not found: \(path)"])
            }
            parent = oid
        }
        return (sid, parent)
    }

    private func resolveEntryLocked(_ path: String) throws -> (UInt32, UInt32, Bool, Int) {
        let segs = Self.pathSegments(path)
        guard let leaf = segs.last else {
            return (try firstStorageIdLocked(), MtpBridge.rootParent, true, 0)
        }
        let parentPath = "/" + segs.dropLast().joined(separator: "/")
        let (sid, parentId) = try resolveFolderLocked(parentPath)
        let children = try bridge.listFolder(inStorage: sid, parent: parentId)
        guard let match = children.first(where: { ($0["name"] as? String) == leaf }),
              let oid = (match["objectId"] as? NSNumber)?.uint32Value else {
            throw NSError(domain: "mtp", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "Not found: \(path)"])
        }
        return (sid, oid,
                (match["isDir"] as? NSNumber)?.boolValue ?? false,
                (match["sizeBytes"] as? NSNumber)?.intValue ?? 0)
    }

    // MARK: - Helpers

    private func ensureOpen() throws {
        if bridge.isOpen { return }
        try bridge.openFirstDevice()
    }

    /// Builds a throttled libmtp progress block that also computes speed and
    /// honors cancellation.
    private func makeProgress(_ transferId: String, fallbackTotal: Int) -> MtpProgressBlock {
        var lastEmit = Date(timeIntervalSince1970: 0)
        var lastBytes = 0
        var lastTime = Date()
        return { [weak self] sent, tot in
            guard let self = self else { return true }
            if self.isCancelled(transferId) { return false }
            let now = Date()
            let done = Int(sent)
            let total = tot > 0 ? Int(tot) : fallbackTotal
            if now.timeIntervalSince(lastEmit) >= 0.2 || done >= total {
                let dt = now.timeIntervalSince(lastTime)
                let speed = dt > 0 ? Int(Double(done - lastBytes) / dt) : 0
                lastBytes = done
                lastTime = now
                lastEmit = now
                self.emitProgress(transferId, done: done, total: total, speed: max(0, speed))
            }
            return true
        }
    }

    private func finishError(_ transferId: String, error: Error) {
        if consumeCancelled(transferId) {
            emitDone(transferId, success: false, error: "Cancelled")
        } else {
            emitDone(transferId, success: false, error: error.localizedDescription)
        }
    }

    private func isCancelled(_ id: String) -> Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }
        return cancelled.contains(id)
    }

    private func consumeCancelled(_ id: String) -> Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }
        return cancelled.remove(id) != nil
    }

    private func emitProgress(_ id: String, done: Int, total: Int, speed: Int) {
        let pct = total > 0 ? min(100, Int(Double(done) / Double(total) * 100)) : 0
        FileBridgeEvents.shared.send([
            "type": "transferProgress", "transferId": id,
            "percent": pct, "bytesDone": done, "bytesTotal": total, "speedBps": speed,
        ])
    }

    private func emitDone(_ id: String, success: Bool, error: String?) {
        var event: [String: Any] = ["type": "transferDone", "transferId": id, "success": success]
        if let error = error { event["error"] = error }
        FileBridgeEvents.shared.send(event)
    }

    private func localSize(_ path: String) -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int else { return 0 }
        return size
    }
}
