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
    g_logPath = [paths[0] stringByAppendingPathComponent:@"ypd_v0.12.log"];
    [[NSFileManager defaultManager] createFileAtPath:g_logPath contents:nil attributes:nil];
    g_logHandle = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
    [g_logHandle seekToEndOfFile];
    g_logLock = [[NSLock alloc] init];
    ypd_log(@"=== YPD v0.12 ===");
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

// ---- Phase 3: Sync command probe (passthrough logging) ----

static void (*orig_syncHandleCommandMsg)(id, SEL, id, id, int, id, id);

static void hook_syncHandleCommandMsg(id self, SEL _cmd, id message, id inbox, int reason, id context, id countMap) {
    NSString *msgType = @"?";
    if ([message respondsToSelector:@selector(serverMessageType)]) {
        msgType = [NSString stringWithFormat:@"%@", [message performSelector:@selector(serverMessageType)]];
    }
    ypd_log(@"PROBE | syncHandleCommandMsg msgType=%@ reason=%d hasInbox=%d hasContext=%d hasCountMap=%d",
            msgType, reason, inbox!=nil, context!=nil, countMap!=nil);
    orig_syncHandleCommandMsg(self, _cmd, message, inbox, reason, context, countMap);
}

static void ypd_hook_sync_command() {
    Class inserter = NSClassFromString(@"TIMXECOMMessageInserter");
    if (!inserter) { ypd_log(@"PROBE | TIMXECOMMessageInserter NOT FOUND"); return; }
    SEL sel = NSSelectorFromString(@"syncHandleCommandMessage:inInbox:reason:context:countMap:");
    MSHookMessageEx(inserter, sel, (IMP)&hook_syncHandleCommandMsg, (IMP*)&orig_syncHandleCommandMsg);
    ypd_log(@"PROBE | syncHandleCommandMessage HOOKED (passthrough)");
}

%ctor {
    @autoreleasepool {
        ypd_init_log();

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
        ypd_hook_sync_command();

        ypd_log(@"=== YPD v0.12 init complete ===");
    }
}
