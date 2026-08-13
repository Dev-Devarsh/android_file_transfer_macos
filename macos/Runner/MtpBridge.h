#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Progress callback: return YES to CONTINUE, NO to CANCEL the transfer.
typedef BOOL (^MtpProgressBlock)(uint64_t sent, uint64_t total);

/// Thin Objective-C wrapper over libmtp. All calls are synchronous and NOT
/// thread-safe — the Swift layer serialises every call onto one queue, because
/// MTP is a single-channel-per-device protocol.
///
/// Objects are identified by (storageId, objectId); there are no paths. The
/// root of a storage is addressed with `MtpRootParent`.
@interface MtpBridge : NSObject

/// Sentinel parent id for the root of a storage.
@property (class, nonatomic, readonly) uint32_t rootParent;

/// True while a device is open.
@property (nonatomic, readonly) BOOL isOpen;

/// Detect and open the first MTP device. Returns NO (with error) if none is
/// present or it can't be claimed. Idempotent-ish: closes any prior handle.
- (BOOL)openFirstDeviceWithError:(NSError **)error;

/// Close the current device handle (frees the USB claim).
- (void)closeDevice;

/// Whether an MTP device is currently attached (cheap raw-detect; does not open).
- (BOOL)devicePresent;

/// {serial, model} of the open device (empty strings if unknown).
- (NSDictionary<NSString *, NSString *> *)deviceInfo;

/// Storages on the open device. Each: {storageId (NSNumber u32), description,
/// freeBytes (NSNumber u64), maxBytes (NSNumber u64)}.
- (NSArray<NSDictionary<NSString *, id> *> *)storages;

/// Entries directly under `parentId` in `storageId`. Each: {objectId, name,
/// isDir, sizeBytes, modifiedEpoch, storageId}. Returns nil on error.
- (nullable NSArray<NSDictionary<NSString *, id> *> *)listFolderInStorage:(uint32_t)storageId
                                                                   parent:(uint32_t)parentId
                                                                    error:(NSError **)error;

/// Pull object `objectId` to local `destPath`.
- (BOOL)getObject:(uint32_t)objectId
           toPath:(NSString *)destPath
         progress:(nullable MtpProgressBlock)progress
            error:(NSError **)error;

/// Push local `srcPath` into (storageId, parentId) as `name`. Returns the new
/// object id, or 0 on failure.
- (uint32_t)sendFile:(NSString *)srcPath
             storage:(uint32_t)storageId
              parent:(uint32_t)parentId
                name:(NSString *)name
                size:(uint64_t)size
            progress:(nullable MtpProgressBlock)progress
               error:(NSError **)error;

/// Delete a file or (recursively, best-effort) a folder object.
- (BOOL)deleteObject:(uint32_t)objectId error:(NSError **)error;

/// Create a folder `name` under (storageId, parentId). Returns new id or 0.
- (uint32_t)createFolder:(NSString *)name
                 storage:(uint32_t)storageId
                  parent:(uint32_t)parentId
                   error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
