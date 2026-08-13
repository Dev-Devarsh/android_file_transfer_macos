#import "MtpBridge.h"
#import <libmtp.h>

/// libmtp progress trampoline: unwrap the Obj-C block from `data` and translate
/// its BOOL (YES=continue) into libmtp's convention (return non-zero to cancel).
static int mtp_progress_cb(uint64_t const sent, uint64_t const total, void const *const data) {
    if (data == NULL) return 0;
    MtpProgressBlock block = (__bridge MtpProgressBlock)data;
    return block(sent, total) ? 0 : 1;
}

@implementation MtpBridge {
    LIBMTP_mtpdevice_t *_device;
}

+ (uint32_t)rootParent {
    return LIBMTP_FILES_AND_FOLDERS_ROOT;
}

- (instancetype)init {
    if ((self = [super init])) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{ LIBMTP_Init(); });
        _device = NULL;
    }
    return self;
}

- (void)dealloc {
    [self closeDevice];
}

- (BOOL)isOpen {
    return _device != NULL;
}

- (BOOL)openFirstDeviceWithError:(NSError **)error {
    [self closeDevice];

    LIBMTP_raw_device_t *rawdevices = NULL;
    int numraw = 0;
    LIBMTP_error_number_t err = LIBMTP_Detect_Raw_Devices(&rawdevices, &numraw);
    if (err != LIBMTP_ERROR_NONE || numraw < 1) {
        if (rawdevices) free(rawdevices);
        if (error) {
            *error = [self makeError:@"No device found. Plug in the phone and choose "
                                     @"“File Transfer” on it (swipe down → USB notification)."];
        }
        return NO;
    }

    LIBMTP_mtpdevice_t *device = LIBMTP_Open_Raw_Device_Uncached(&rawdevices[0]);
    free(rawdevices);
    if (device == NULL) {
        if (error) {
            *error = [self makeError:@"Found a device but couldn’t open it. It may be busy — "
                                     @"quit Android File Transfer if it’s running, or replug the cable."];
        }
        return NO;
    }

    // Populate the storage list so `storages` and free-space work.
    LIBMTP_Get_Storage(device, LIBMTP_STORAGE_SORTBY_NOTSORTED);
    _device = device;
    return YES;
}

- (void)closeDevice {
    if (_device) {
        LIBMTP_Release_Device(_device);
        _device = NULL;
    }
}

- (BOOL)devicePresent {
    if (_device) return YES;
    LIBMTP_raw_device_t *rawdevices = NULL;
    int numraw = 0;
    LIBMTP_error_number_t err = LIBMTP_Detect_Raw_Devices(&rawdevices, &numraw);
    if (rawdevices) free(rawdevices);
    return (err == LIBMTP_ERROR_NONE && numraw > 0);
}

- (NSDictionary<NSString *, NSString *> *)deviceInfo {
    if (!_device) return @{@"serial": @"", @"model": @""};
    char *serial = LIBMTP_Get_Serialnumber(_device);
    char *model = LIBMTP_Get_Modelname(_device);
    char *friendly = LIBMTP_Get_Friendlyname(_device);

    NSString *ser = serial ? @(serial) : @"";
    NSString *mod = (friendly && strlen(friendly)) ? @(friendly)
                  : (model ? @(model) : @"MTP device");

    if (serial) free(serial);
    if (model) free(model);
    if (friendly) free(friendly);
    return @{@"serial": ser, @"model": mod};
}

- (NSArray<NSDictionary<NSString *, id> *> *)storages {
    NSMutableArray *out = [NSMutableArray array];
    if (!_device) return out;
    for (LIBMTP_devicestorage_t *s = _device->storage; s != NULL; s = s->next) {
        [out addObject:@{
            @"storageId": @(s->id),
            @"description": s->StorageDescription ? @(s->StorageDescription) : @"Storage",
            @"freeBytes": @(s->FreeSpaceInBytes),
            @"maxBytes": @(s->MaxCapacity),
        }];
    }
    return out;
}

- (NSArray<NSDictionary<NSString *, id> *> *)listFolderInStorage:(uint32_t)storageId
                                                          parent:(uint32_t)parentId
                                                           error:(NSError **)error {
    if (!_device) {
        if (error) *error = [self makeError:@"No device open"];
        return nil;
    }

    LIBMTP_file_t *files = LIBMTP_Get_Files_And_Folders(_device, storageId, parentId);
    NSMutableArray *out = [NSMutableArray array];
    for (LIBMTP_file_t *f = files; f != NULL; ) {
        BOOL isDir = (f->filetype == LIBMTP_FILETYPE_FOLDER);
        [out addObject:@{
            @"objectId": @(f->item_id),
            @"name": f->filename ? @(f->filename) : @"",
            @"isDir": @(isDir),
            @"sizeBytes": @((long long)f->filesize),
            @"modifiedEpoch": @((long long)f->modificationdate),
            @"storageId": @(f->storage_id),
        }];
        LIBMTP_file_t *tmp = f;
        f = f->next;
        LIBMTP_destroy_file_t(tmp);
    }

    // A NULL list with a non-empty error stack means a real failure (vs. an
    // empty folder, which also returns NULL).
    if (files == NULL && LIBMTP_Get_Errorstack(_device) != NULL) {
        if (error) *error = [self makeError:@"Could not read folder"];
        return nil;
    }
    return out;
}

- (BOOL)getObject:(uint32_t)objectId
           toPath:(NSString *)destPath
         progress:(MtpProgressBlock)progress
            error:(NSError **)error {
    if (!_device) {
        if (error) *error = [self makeError:@"No device open"];
        return NO;
    }
    int ret = LIBMTP_Get_File_To_File(_device, objectId, destPath.fileSystemRepresentation,
                                      progress ? mtp_progress_cb : NULL,
                                      progress ? (__bridge void *)progress : NULL);
    if (ret != 0) {
        if (error) *error = [self makeError:@"Copy from phone failed"];
        return NO;
    }
    return YES;
}

- (uint32_t)sendFile:(NSString *)srcPath
             storage:(uint32_t)storageId
              parent:(uint32_t)parentId
                name:(NSString *)name
                size:(uint64_t)size
            progress:(MtpProgressBlock)progress
               error:(NSError **)error {
    if (!_device) {
        if (error) *error = [self makeError:@"No device open"];
        return 0;
    }
    LIBMTP_file_t *gen = LIBMTP_new_file_t();
    gen->filesize = size;
    gen->filename = strdup(name.UTF8String);
    gen->filetype = LIBMTP_FILETYPE_UNKNOWN;
    gen->parent_id = parentId;
    gen->storage_id = storageId;

    int ret = LIBMTP_Send_File_From_File(_device, srcPath.fileSystemRepresentation, gen,
                                         progress ? mtp_progress_cb : NULL,
                                         progress ? (__bridge void *)progress : NULL);
    uint32_t newId = (ret == 0) ? gen->item_id : 0;
    LIBMTP_destroy_file_t(gen);

    if (ret != 0) {
        if (error) *error = [self makeError:@"Copy to phone failed"];
        return 0;
    }
    return newId;
}

- (BOOL)deleteObject:(uint32_t)objectId error:(NSError **)error {
    if (!_device) {
        if (error) *error = [self makeError:@"No device open"];
        return NO;
    }
    int ret = LIBMTP_Delete_Object(_device, objectId);
    if (ret != 0) {
        if (error) *error = [self makeError:@"Delete failed"];
        return NO;
    }
    return YES;
}

- (uint32_t)createFolder:(NSString *)name
                 storage:(uint32_t)storageId
                  parent:(uint32_t)parentId
                   error:(NSError **)error {
    if (!_device) {
        if (error) *error = [self makeError:@"No device open"];
        return 0;
    }
    char *cname = strdup(name.UTF8String);
    uint32_t newId = LIBMTP_Create_Folder(_device, cname, parentId, storageId);
    free(cname);
    if (newId == 0) {
        if (error) *error = [self makeError:@"Create folder failed"];
        return 0;
    }
    return newId;
}

// MARK: - Errors

/// Builds an NSError, appending any libmtp error-stack text, then clears it.
- (NSError *)makeError:(NSString *)message {
    NSMutableString *full = [message mutableCopy];
    if (_device) {
        LIBMTP_error_t *stack = LIBMTP_Get_Errorstack(_device);
        for (LIBMTP_error_t *e = stack; e != NULL; e = e->next) {
            if (e->error_text) {
                [full appendFormat:@" (%s)", e->error_text];
            }
        }
        LIBMTP_Clear_Errorstack(_device);
    }
    return [NSError errorWithDomain:@"MtpBridge"
                               code:-1
                           userInfo:@{NSLocalizedDescriptionKey: full}];
}

@end
