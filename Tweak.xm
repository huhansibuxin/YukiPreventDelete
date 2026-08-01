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
    // Use Documents instead of tmp (tmp may be cleared)
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    g_logPath = [paths[0] stringByAppendingPathComponent:@"ypd_v0.5.log"];
    [[NSFileManager defaultManager] createFileAtPath:g_logPath contents:nil attributes:nil];
    g_logHandle = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
    [g_logHandle seekToEndOfFile];
    g_logLock = [[NSLock alloc] init];
    ypd_log(@"=== YPD v0.5 started, log: %@ ===", g_logPath);
}

// ---- specific hooks for known void-returning delete methods ----

static void (*orig_deleteMessage_sc)(id, SEL, id, BOOL, id);
static void hook_deleteMessage_sc(id self, SEL _cmd, id msg, BOOL send, id comp) {
    ypd_log(@"BLOCK | AWEIMNewMsgDC | deleteMessage:sendToServer:completion: send=%d", send);
    // Don't call original - block deletion
}

static void (*orig_deleteMessage_ss)(id, SEL, id, BOOL);
static void hook_deleteMessage_ss(id self, SEL _cmd, id msg, BOOL send) {
    ypd_log(@"BLOCK | AWEIMNewMsgDC | deleteMessage:sendToServer: send=%d", send);
}

static void (*orig_deleteMessageInMemory)(id, SEL, id);
static void hook_deleteMessageInMemory(id self, SEL _cmd, id msg) {
    ypd_log(@"BLOCK | AWEIMNewMsgDC | deleteMessageInMemory:");
}

static void (*orig_deleteMessageInMemory_sr)(id, SEL, id, BOOL);
static void hook_deleteMessageInMemory_sr(id self, SEL _cmd, id msg, BOOL reload) {
    ypd_log(@"BLOCK | AWEIMNewMsgDC | deleteMessageInMemory:shouldReload: reload=%d", reload);
}

static void (*orig_batchDeleteMessageIds)(id, SEL, id);
static void hook_batchDeleteMessageIds(id self, SEL _cmd, id arr) {
    ypd_log(@"BLOCK | AWEIMNewMsgDC | batchDeleteMessageIds: count=%lu", (unsigned long)[arr count]);
}

// ---- runtime scan: hook only void-returning delete methods, log the rest ----

static void ypd_block_void(id self, SEL _cmd) {
    ypd_log(@"BLOCK | %@ | %@", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
}

static void ypd_scan_and_hook() {
    unsigned int classCount;
    Class *classes = objc_copyClassList(&classCount);
    NSMutableSet *hooked = [NSMutableSet set];
    NSUInteger voidCount = 0, otherCount = 0;

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
            [hooked addObject:key];

            Method m = class_getInstanceMethod(classes[i], sel);
            if (!m) continue;

            const char *types = method_getTypeEncoding(m);
            char retType = types[0];

            if (retType == 'v') {
                // void return - safe to block
                ypd_log(@"HOOK_VOID | %@ | %@", className, selName);
                MSHookMessageEx(classes[i], sel, (IMP)&ypd_block_void, NULL);
                voidCount++;
            } else {
                // Non-void - just log that we found it, don't hook (would crash)
                ypd_log(@"SKIP_NONVOID | %@ | %@ (ret=%c)", className, selName, retType);
                otherCount++;
            }
        }
        free(methods);
    }
    free(classes);
    ypd_log(@"=== Scan done: %lu void hooked, %lu non-void skipped ===", (unsigned long)voidCount, (unsigned long)otherCount);
}

%ctor {
    @autoreleasepool {
        ypd_init_log();

        // Phase 1: specific hooks on known class
        Class msgDC = NSClassFromString(@"AWEIMNewMessageDataController");
        if (msgDC) {
            ypd_log(@"PHASE1 | Found AWEIMNewMessageDataController");
            MSHookMessageEx(msgDC, NSSelectorFromString(@"deleteMessage:sendToServer:completion:"), (IMP)&hook_deleteMessage_sc, (IMP*)&orig_deleteMessage_sc);
            MSHookMessageEx(msgDC, NSSelectorFromString(@"deleteMessage:sendToServer:"), (IMP)&hook_deleteMessage_ss, (IMP*)&orig_deleteMessage_ss);
            MSHookMessageEx(msgDC, NSSelectorFromString(@"deleteMessageInMemory:"), (IMP)&hook_deleteMessageInMemory, (IMP*)&orig_deleteMessageInMemory);
            MSHookMessageEx(msgDC, NSSelectorFromString(@"deleteMessageInMemory:shouldReload:"), (IMP)&hook_deleteMessageInMemory_sr, (IMP*)&orig_deleteMessageInMemory_sr);
            MSHookMessageEx(msgDC, NSSelectorFromString(@"batchDeleteMessageIds:"), (IMP)&hook_batchDeleteMessageIds, (IMP*)&orig_batchDeleteMessageIds);
            ypd_log(@"PHASE1 | 5 delete hooks installed");
        } else {
            ypd_log(@"PHASE1 | AWEIMNewMessageDataController NOT FOUND");
        }

        // Phase 2: runtime scan for additional void-returning delete methods
        ypd_log(@"PHASE2 | Starting runtime scan...");
        ypd_scan_and_hook();
    }
}
