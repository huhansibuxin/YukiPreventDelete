#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/runtime.h>

static NSString *g_logPath;
static NSFileHandle *g_logHandle;
static NSLock *g_logLock;

static void ypd_log(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
    [g_logLock lock];
    [g_logHandle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [g_logHandle synchronizeFile];
    [g_logLock unlock];
}

static void ypd_init_log() {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    g_logPath = [paths[0] stringByAppendingPathComponent:@"ypd_v0.7.log"];
    [[NSFileManager defaultManager] createFileAtPath:g_logPath contents:nil attributes:nil];
    g_logHandle = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
    [g_logHandle seekToEndOfFile];
    g_logLock = [[NSLock alloc] init];
    ypd_log(@"=== YPD v0.7 diag ===");
}

// ---- Phase 1: AWEIMNewMessageDataController void delete (block) ----

static void hook_block_delMsg_sc(id self, SEL _cmd, id msg, BOOL send, id comp) {
    ypd_log(@"BLOCK | NewMsgDC | deleteMessage:sendToServer:completion: send=%d", send);
}
static void hook_block_delMsg_ss(id self, SEL _cmd, id msg, BOOL send) {
    ypd_log(@"BLOCK | NewMsgDC | deleteMessage:sendToServer: send=%d", send);
}
static void hook_block_delMsgInMem(id self, SEL _cmd, id msg) {
    ypd_log(@"BLOCK | NewMsgDC | deleteMessageInMemory:");
}
static void hook_block_delMsgInMem_sr(id self, SEL _cmd, id msg, BOOL reload) {
    ypd_log(@"BLOCK | NewMsgDC | deleteMessageInMemory:shouldReload: reload=%d", reload);
}
static void hook_block_batchDel(id self, SEL _cmd, id arr) {
    ypd_log(@"BLOCK | NewMsgDC | batchDeleteMessageIds: count=%lu", (unsigned long)[arr count]);
}

// ---- Phase 2: all void delete methods (block) ----

static void ypd_block_void(id self, SEL _cmd) {
    ypd_log(@"BLOCK | %@ | %@", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
}

// ---- Diagnostic: log ALL method calls on key sync classes (PASSTHROUGH) ----

@interface NSObject (YPDDiag)
@end
@implementation NSObject (YPDDiag)
- (void)ypd_diag_log {
    ypd_log(@"DIAG | %@ | %@", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
}
@end

static void ypd_diag_hook_all(Class cls, NSString *className) {
    unsigned int count;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        NSString *selName = NSStringFromSelector(sel);
        // Skip init/dealloc/retain/release type methods
        if ([selName hasPrefix:@"init"] || [selName hasPrefix:@"dealloc"] ||
            [selName hasPrefix:@"."] || [selName hasPrefix:@"_"] ||
            [selName isEqualToString:@"class"] || [selName isEqualToString:@"hash"] ||
            [selName isEqualToString:@"superclass"] || [selName isEqualToString:@"self"] ||
            [selName hasPrefix:@"retain"] || [selName hasPrefix:@"release"] ||
            [selName hasPrefix:@"autorelease"] || [selName hasPrefix:@"alloc"] ||
            [selName hasPrefix:@"copy"] || [selName hasPrefix:@"mutableCopy"] ||
            [selName hasPrefix:@"new"] || [selName hasPrefix:@"zone"] ||
            [selName hasPrefix:@"performSelector"] || [selName hasPrefix:@"respondsTo"] ||
            [selName hasPrefix:@"conformsTo"] || [selName hasPrefix:@"isKindOf"] ||
            [selName hasPrefix:@"isMemberOf"] || [selName hasPrefix:@"isProxy"] ||
            [selName hasPrefix:@"methodFor"] || [selName hasPrefix:@"instanceMethod"] ||
            [selName hasPrefix:@"doesNotRecognize"] || [selName hasPrefix:@"forward"] ||
            [selName hasPrefix:@"description"] || [selName hasPrefix:@"debugDescription"] ||
            [selName hasPrefix:@"valueFor"] || [selName hasPrefix:@"setValue"] ||
            [selName hasPrefix:@"setObservation"] || [selName hasPrefix:@"observation"] ||
            [selName hasPrefix:@"willChange"] || [selName hasPrefix:@"didChange"] ||
            [selName hasPrefix:@"observeValue"] || [selName hasPrefix:@"addObserver"] ||
            [selName hasPrefix:@"removeObserver"]) continue;
            
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) continue;
        const char *types = method_getTypeEncoding(m);
        if (types[0] != 'v') continue; // only void for diag logging
        if ([selName.lowercaseString containsString:@"delete"]) continue; // already covered by Phase2
        
        MSHookMessageEx(cls, sel, (IMP)@selector(ypd_diag_log), NULL);
    }
    free(methods);
    ypd_log(@"DIAG_HOOK | %@ | all void methods passthrough-logged", className);
}

// ---- Phase 2 scanner ----

static void ypd_scan_void_delete() {
    unsigned int classCount;
    Class *classes = objc_copyClassList(&classCount);
    NSMutableSet *hooked = [NSMutableSet set];
    NSUInteger voidCount = 0;

    for (unsigned int i = 0; i < classCount; i++) {
        NSString *className = NSStringFromClass(classes[i]);
        if (![className containsString:@"EIM"] &&
            ![className containsString:@"Message"] &&
            ![className containsString:@"Chat"] &&
            ![className containsString:@"FlowIM"]) continue;

        unsigned int methodCount;
        Method *methods = class_copyMethodList(classes[i], &methodCount);
        for (unsigned int j = 0; j < methodCount; j++) {
            SEL sel = method_getName(methods[j]);
            NSString *selName = NSStringFromSelector(sel);
            if (![selName.lowercaseString containsString:@"delete"]) continue;

            NSString *key = [NSString stringWithFormat:@"%@|%@", className, selName];
            if ([hooked containsObject:key]) continue;
            
            Method m = class_getInstanceMethod(classes[i], sel);
            if (!m) continue;
            const char *types = method_getTypeEncoding(m);
            if (types[0] != 'v') continue;
            
            [hooked addObject:key];
            MSHookMessageEx(classes[i], sel, (IMP)&ypd_block_void, NULL);
            voidCount++;
        }
        free(methods);
    }
    free(classes);
    ypd_log(@"SCAN | %lu void delete methods BLOCKED", (unsigned long)voidCount);
}

%ctor {
    @autoreleasepool {
        ypd_init_log();

        // Phase 1: AWEIMNewMessageDataController
        Class msgDC = NSClassFromString(@"AWEIMNewMessageDataController");
        if (msgDC) {
            MSHookMessageEx(msgDC, NSSelectorFromString(@"deleteMessage:sendToServer:completion:"), (IMP)&hook_block_delMsg_sc, NULL);
            MSHookMessageEx(msgDC, NSSelectorFromString(@"deleteMessage:sendToServer:"), (IMP)&hook_block_delMsg_ss, NULL);
            MSHookMessageEx(msgDC, NSSelectorFromString(@"deleteMessageInMemory:"), (IMP)&hook_block_delMsgInMem, NULL);
            MSHookMessageEx(msgDC, NSSelectorFromString(@"deleteMessageInMemory:shouldReload:"), (IMP)&hook_block_delMsgInMem_sr, NULL);
            MSHookMessageEx(msgDC, NSSelectorFromString(@"batchDeleteMessageIds:"), (IMP)&hook_block_batchDel, NULL);
            ypd_log(@"P1 | NewMsgDC 5 hooks OK");
        } else {
            ypd_log(@"P1 | NewMsgDC NOT FOUND");
        }

        // Phase 2: scan all void delete methods -> block
        ypd_scan_void_delete();

        // Diagnostic: hook all void methods on key sync classes (passthrough log)
        NSArray *diagClasses = @[
            @"TIMXECOMMessageInserter",
            @"TIMXECOMMessageNewStore",
            @"IESMultiDeviceMessageDelegate",
            @"IESLiveScreencastMultiDeviceMessageDelegate",
            @"TIMXOMessageNotifier",
            @"TIMXOThirdPartyMessageNotifier",
        ];
        for (NSString *cn in diagClasses) {
            Class cls = NSClassFromString(cn);
            if (cls) {
                ypd_diag_hook_all(cls, cn);
            } else {
                ypd_log(@"DIAG | %@ NOT FOUND", cn);
            }
        }

        ypd_log(@"=== YPD v0.7 init complete ===");
    }
}
