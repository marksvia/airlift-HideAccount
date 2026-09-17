#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>

typedef const void *AMDeviceRef;
typedef const void *AMDeviceNotificationRef;
typedef void *AMDServiceConnectionRef;
typedef void *AFCConnectionRef;
typedef void *AFCFileRef;

typedef struct {
    AMDeviceRef device;
    unsigned int message;
} AMDeviceNotificationCallbackInfo;

extern int AMDeviceNotificationSubscribeWithOptions(
    void (*callback)(AMDeviceNotificationCallbackInfo *, void *),
    int unused,
    unsigned int connectionType,
    void *context,
    AMDeviceNotificationRef *subscription,
    CFDictionaryRef options);
extern int AMDeviceNotificationUnsubscribe(AMDeviceNotificationRef subscription);
extern CFStringRef AMDeviceCopyDeviceIdentifier(AMDeviceRef device);
extern int AMDeviceConnect(AMDeviceRef device);
extern int AMDeviceDisconnect(AMDeviceRef device);
extern int AMDeviceValidatePairing(AMDeviceRef device);
extern int AMDeviceStartSession(AMDeviceRef device);
extern int AMDeviceStopSession(AMDeviceRef device);
extern int AMDeviceSecureStartService(AMDeviceRef device,
                                      CFStringRef serviceName,
                                      CFDictionaryRef options,
                                      AMDServiceConnectionRef *connection);
extern int AMDServiceConnectionGetSocket(AMDServiceConnectionRef connection);
extern void *AMDServiceConnectionGetSecureIOContext(
    AMDServiceConnectionRef connection);
extern int AMDServiceConnectionInvalidate(AMDServiceConnectionRef connection);

extern int AFCConnectionOpen(int socket,
                             unsigned int ioTimeout,
                             AFCConnectionRef *connection);
extern int AFCConnectionClose(AFCConnectionRef connection);
extern int AFCConnectionSetSecureContext(AFCConnectionRef connection,
                                         void *secureContext);
extern int AFCConnectionSetDisposeSecureContextOnInvalidate(
    AFCConnectionRef connection,
    int dispose);
extern int AFCConnectionSetIOTimeout(AFCConnectionRef connection,
                                     unsigned int timeout);
extern int AFCFileRefOpen(AFCConnectionRef connection,
                          const char *path,
                          unsigned long long mode,
                          AFCFileRef *file);
extern int AFCFileRefWrite(AFCConnectionRef connection,
                           AFCFileRef file,
                           const void *bytes,
                           long length);
extern int AFCFileRefClose(AFCConnectionRef connection, AFCFileRef file);

static CFStringRef TargetIdentifier;
static AMDeviceRef TargetDevice;

static void DeviceCallback(AMDeviceNotificationCallbackInfo *info,
                           void *context) {
    (void)context;
    if (!info || !info->device || info->message != 1 || TargetDevice) return;
    CFStringRef identifier = AMDeviceCopyDeviceIdentifier(info->device);
    BOOL matches = identifier && CFEqual(identifier, TargetIdentifier);
    if (identifier) CFRelease(identifier);
    if (!matches) return;
    TargetDevice = CFRetain(info->device);
    CFRunLoopStop(CFRunLoopGetMain());
}

static int FindTarget(void) {
    NSDictionary *options = @{
        @"NotificationOptionSearchForPairedDevices": @YES,
        @"NotificationOptionSearchForPairedDevicesViaDirectConnectionsOnly": @NO,
        @"NotificationOptionSearchForWiFiPairableDevices": @NO,
        @"NotificationOptionEnableRemoteXPC": @YES,
        @"NotificationOptionEnableUSBMux": @YES,
    };
    AMDeviceNotificationRef subscription = NULL;
    int status = AMDeviceNotificationSubscribeWithOptions(
        DeviceCallback,
        0,
        0,
        NULL,
        &subscription,
        (__bridge CFDictionaryRef)options);
    if (status == 0)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 30.0, false);
    if (subscription) AMDeviceNotificationUnsubscribe(subscription);
    return status;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 4) {
            fprintf(stderr, "Usage: %s <udid> <target_path> <payload_file>\n", argv[0]);
            return 1;
        }

        TargetIdentifier = CFStringCreateWithCString(
            kCFAllocatorDefault, argv[1], kCFStringEncodingUTF8);
        NSString *targetPath = [NSString stringWithUTF8String:argv[2]];
        NSString *payloadFile = [NSString stringWithUTF8String:argv[3]];

        NSData *payload = [NSData dataWithContentsOfFile:payloadFile];
        if (!payload) {
            fprintf(stderr, "Error: Cannot read payload file\n");
            return 1;
        }

        fprintf(stderr, "[*] Searching for device...\n");
        int findStatus = FindTarget();
        if (findStatus != 0 || !TargetDevice) {
            fprintf(stderr, "[✗] Device not found\n");
            return 2;
        }

        fprintf(stderr, "[*] Connecting to device...\n");
        int connectStatus = AMDeviceConnect(TargetDevice);
        if (connectStatus != 0) {
            fprintf(stderr, "[✗] Connection failed: %d\n", connectStatus);
            CFRelease(TargetDevice);
            return 3;
        }

        int validateStatus = AMDeviceValidatePairing(TargetDevice);
        if (validateStatus != 0) {
            fprintf(stderr, "[✗] Pairing validation failed: %d\n", validateStatus);
            AMDeviceDisconnect(TargetDevice);
            CFRelease(TargetDevice);
            return 4;
        }

        int sessionStatus = AMDeviceStartSession(TargetDevice);
        if (sessionStatus != 0) {
            fprintf(stderr, "[✗] Failed to start session: %d\n", sessionStatus);
            AMDeviceDisconnect(TargetDevice);
            CFRelease(TargetDevice);
            return 5;
        }

        fprintf(stderr, "[*] Starting AFC service (crashreportcopymobile)...\n");
        AMDServiceConnectionRef afcService = NULL;
        int serviceStatus = AMDeviceSecureStartService(
            TargetDevice,
            CFSTR("com.apple.crashreportcopymobile"),
            NULL,
            &afcService);
        if (serviceStatus != 0 || !afcService) {
            fprintf(stderr, "[✗] Failed to start AFC service: %d\n", serviceStatus);
            AMDeviceStopSession(TargetDevice);
            AMDeviceDisconnect(TargetDevice);
            CFRelease(TargetDevice);
            return 6;
        }

        AFCConnectionRef afc = NULL;
        int afcStatus = AFCConnectionOpen(
            AMDServiceConnectionGetSocket(afcService),
            0,
            &afc);
        if (afcStatus != 0 || !afc) {
            fprintf(stderr, "[✗] Failed to open AFC connection: %d\n", afcStatus);
            AMDServiceConnectionInvalidate(afcService);
            AMDeviceStopSession(TargetDevice);
            AMDeviceDisconnect(TargetDevice);
            CFRelease(TargetDevice);
            return 7;
        }

        void *secureContext = AMDServiceConnectionGetSecureIOContext(afcService);
        if (secureContext) {
            AFCConnectionSetSecureContext(afc, secureContext);
            AFCConnectionSetDisposeSecureContextOnInvalidate(afc, 0);
            AFCConnectionSetIOTimeout(afc, 30);
        }

        fprintf(stderr, "[*] Writing file: %s\n", [targetPath UTF8String]);
        fprintf(stderr, "[*] Payload size: %lu bytes\n", (unsigned long)payload.length);

        // Use AFC mode 3 to create or truncate the file before writing.
        AFCFileRef file = NULL;
        int openStatus = AFCFileRefOpen(
            afc,
            [targetPath UTF8String],
            3,  // Mode 3: create or truncate.
            &file);

        if (openStatus != 0 || !file) {
            fprintf(stderr, "[✗] Failed to open file: %d\n", openStatus);
            AFCConnectionClose(afc);
            AMDServiceConnectionInvalidate(afcService);
            AMDeviceStopSession(TargetDevice);
            AMDeviceDisconnect(TargetDevice);
            CFRelease(TargetDevice);
            return 8;
        }

        int writeStatus = AFCFileRefWrite(
            afc,
            file,
            payload.bytes,
            (long)payload.length);

        int closeStatus = AFCFileRefClose(afc, file);

        if (writeStatus == 0 && closeStatus == 0) {
            fprintf(stderr, "[✓] Write succeeded!\n");
        } else {
            fprintf(stderr, "[✗] Write failed: write=%d, close=%d\n",
                    writeStatus, closeStatus);
        }

        AFCConnectionClose(afc);
        AMDServiceConnectionInvalidate(afcService);
        AMDeviceStopSession(TargetDevice);
        AMDeviceDisconnect(TargetDevice);
        CFRelease(TargetDevice);
        CFRelease(TargetIdentifier);

        return (writeStatus == 0 && closeStatus == 0) ? 0 : 9;
    }
}
