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
    g_logPath = [paths[0] stringByAppendingPathComponent:@"ypd_v0.10.log"];
    [[NSFileManager defaultManager] createFileAtPath:g_logPath contents:nil attributes:nil];
    g_logHandle = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
    [g_logHandle seekToEndOfFile];
    g_logLock = [[NSLock alloc] init];
    ypd_log(@"=== YPD v0.10 ===");
}

static void ypd_dump_methods(Class cls, NSString *name) {
    unsigned int count;
    Method *methods = class_copyMethodList(cls, &count);
    ypd_log(@"=== %@ methods (%u) ===", name, count);
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        ypd_log(@"  %@", NSStringFromSelector(sel));
    }
    free(methods);
}

// ---- Phase 1: AWEIMNewMessageDataController ----

static void hook_delMsg_sc(id self, SEL _cmd, id msg, BOOL send, id comp) {
    ypd_log(@"BLOCK | NewMsgDC | deleteMsg:send:completion: send=%d", send);
}
static void hook_delMsg_ss(id self, SEL _cmd, id msg, BOOL send) {
    ypd_log(@"BLOCK | NewMsgDC | deleteMsg:send: send=%d", send);
}
static void hook_delMsgInMem(id self, SEL _cmd, id msg) {
    ypd_log(@"BLOCK | NewMsgDC | deleteMsgInMemory:");
}
static void hook_delMsgInMem_sr(id self, SEL _cmd, id msg, BOOL reload) {
    ypd_log(@"BLOCK | NewMsgDC | deleteMsgInMemory:shouldReload: reload=%d", reload);
}
static void hook_batchDel(id self, SEL _cmd, id arr) {
    ypd_log(@"BLOCK | NewMsgDC | batchDeleteMsgIds: count=%lu", (unsigned long)[arr count]);
}

// ---- Phase 2: void delete blocker (expanded filter) ----

static void ypd_block_void(id self, SEL _cmd) {
    ypd_log(@"BLOCK | %@ | %@", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
}

static BOOL ypd_should_scan_class(NSString *cn) {
    if ([cn containsString:@"EIM"]) return YES;
    if ([cn containsString:@"Message"]) return YES;
    if ([cn containsString:@"Chat"]) return YES;
    if ([cn containsString:@"FlowIM"]) return YES;
    if ([cn containsString:@"TIMX"]) return YES;
    if ([cn containsString:@"TIM"]) return YES;
    if ([cn hasPrefix:@"IESMulti"]) return YES;
    if ([cn hasPrefix:@"IESLive"]) return YES;
    if ([cn hasPrefix:@"IESIM"]) return YES;
    return NO;
}

static void ypd_scan_void_delete() {
    unsigned int classCount;
    Class *classes = objc_copyClassList(&classCount);
    NSMutableSet *hooked = [NSMutableSet set];
    NSUInteger voidCount = 0;
    NSUInteger classCount2 = 0;

    for (unsigned int i = 0; i < classCount; i++) {
        NSString *className = NSStringFromClass(classes[i]);
        if (!ypd_should_scan_class(className)) continue;
        classCount2++;

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
    ypd_log(@"SCAN | %lu classes, %lu void delete methods BLOCKED", (unsigned long)classCount2, (unsigned long)voidCount);
}

%ctor {
    @autoreleasepool {
        ypd_init_log();

        // Dump key sync class methods
        Class inserter = NSClassFromString(@"TIMXECOMMessageInserter");
        if (inserter) ypd_dump_methods(inserter, @"TIMXECOMMessageInserter");
        else ypd_log(@"TIMXECOMMessageInserter NOT FOUND");

        Class nms = NSClassFromString(@"TIMXNewMessageStore");
        if (nms) ypd_dump_methods(nms, @"TIMXNewMessageStore");
        else ypd_log(@"TIMXNewMessageStore NOT FOUND");

        Class cmdHandler = NSClassFromString(@"TIMXCommandMessageHandler");
        if (cmdHandler) ypd_dump_methods(cmdHandler, @"TIMXCommandMessageHandler");
        else ypd_log(@"TIMXCommandMessageHandler NOT FOUND");

        // Phase 1
        Class msgDC = NSClassFromString(@"AWEIMNewMessageDataController");
        if (msgDC) {
            MSHookMessageEx(msgDC, NSSelectorFromString(@"deleteMessage:sendToServer:completion:"), (IMP)&hook_delMsg_sc, NULL);
            MSHookMessageEx(msgDC, NSSelectorFromString(@"deleteMessage:sendToServer:"), (IMP)&hook_delMsg_ss, NULL);
            MSHookMessageEx(msgDC, NSSelectorFromString(@"deleteMessageInMemory:"), (IMP)&hook_delMsgInMem, NULL);
            MSHookMessageEx(msgDC, NSSelectorFromString(@"deleteMessageInMemory:shouldReload:"), (IMP)&hook_delMsgInMem_sr, NULL);
            MSHookMessageEx(msgDC, NSSelectorFromString(@"batchDeleteMessageIds:"), (IMP)&hook_batchDel, NULL);
            ypd_log(@"P1 | NewMsgDC 5 hooks OK");
        } else {
            ypd_log(@"P1 | NewMsgDC NOT FOUND");
        }

        ypd_scan_void_delete();

        ypd_log(@"=== YPD v0.10 init complete ===");
    }
}
