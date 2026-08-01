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
    g_logPath = [paths[0] stringByAppendingPathComponent:@"ypd_v0.13.log"];
    [[NSFileManager defaultManager] createFileAtPath:g_logPath contents:nil attributes:nil];
    g_logHandle = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
    [g_logHandle seekToEndOfFile];
    g_logLock = [[NSLock alloc] init];
    ypd_log(@"=== YPD v0.13 ===");
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

// ---- Phase 2: void delete blocker ----

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
    NSUInteger voidCount = 0, classCount2 = 0;

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
            if (method_getTypeEncoding(m)[0] != 'v') continue;
            [hooked addObject:key];
            MSHookMessageEx(classes[i], sel, (IMP)&ypd_block_void, NULL);
            voidCount++;
        }
        free(methods);
    }
    free(classes);
    ypd_log(@"SCAN | %lu classes, %lu void delete BLOCKED", (unsigned long)classCount2, (unsigned long)voidCount);
}

// ---- Phase 3: wide probes (passthrough) ----

// TIMXECOMMessageInserter

static void (*orig_syncCmd)(id, SEL, id, id, int, id, id);
static void hook_syncCmd(id self, SEL _cmd, id msg, id inbox, int reason, id ctx, id cm) {
    NSString *t = [msg respondsToSelector:@selector(serverMessageType)] 
        ? [NSString stringWithFormat:@"%@", [msg performSelector:@selector(serverMessageType)]] : @"?";
    ypd_log(@"PROBE | Inserter.syncHandleCommand msgType=%@ reason=%d", t, reason);
    orig_syncCmd(self, _cmd, msg, inbox, reason, ctx, cm);
}

static void (*orig_handleCmd)(id, SEL, id, id, int, id);
static void hook_handleCmd(id self, SEL _cmd, id msg, id inbox, int reason, id ctx) {
    NSString *t = [msg respondsToSelector:@selector(serverMessageType)]
        ? [NSString stringWithFormat:@"%@", [msg performSelector:@selector(serverMessageType)]] : @"?";
    ypd_log(@"PROBE | Inserter.handleCommand msgType=%@ reason=%d", t, reason);
    orig_handleCmd(self, _cmd, msg, inbox, reason, ctx);
}

static void (*orig_syncInsert)(id, SEL, id, id, id, int, id);
static void hook_syncInsert(id self, SEL _cmd, id msgs, id extra, id inbox, int reason, id ctx) {
    ypd_log(@"PROBE | Inserter.syncInsertMessages reason=%d count=%lu", reason, (unsigned long)[msgs count]);
    orig_syncInsert(self, _cmd, msgs, extra, inbox, reason, ctx);
}

// TIMXNewMessageStore

static void (*orig_clearConv)(id, SEL, id, id, id);
static void hook_clearConv(id self, SEL _cmd, id convId, id orderIdx, id comp) {
    ypd_log(@"PROBE | Store.clearMessagesInConv convId=%@", convId);
    orig_clearConv(self, _cmd, convId, orderIdx, comp);
}

static void (*orig_clearConv2)(id, SEL, id, id, id);
static void hook_clearConv2(id self, SEL _cmd, id conv, id sortBlock, id comp) {
    ypd_log(@"PROBE | Store.clearMessagesWithConv conv=%@", conv);
    orig_clearConv2(self, _cmd, conv, sortBlock, comp);
}

static void (*orig_delByConvIds)(id, SEL, id, id);
static void hook_delByConvIds(id self, SEL _cmd, id convIds, id comp) {
    ypd_log(@"PROBE | Store.deleteMessagesByConvIds convCount=%lu", (unsigned long)[convIds count]);
    orig_delByConvIds(self, _cmd, convIds, comp);
}

static void (*orig_delByMsgIds)(id, SEL, id, id);
static void hook_delByMsgIds(id self, SEL _cmd, id msgIds, id comp) {
    ypd_log(@"PROBE | Store.deleteMessagesByMsgIds msgCount=%lu", (unsigned long)[msgIds count]);
    orig_delByMsgIds(self, _cmd, msgIds, comp);
}

static void ypd_hook_probes() {
    Class inserter = NSClassFromString(@"TIMXECOMMessageInserter");
    Class store = NSClassFromString(@"TIMXNewMessageStore");

    if (inserter) {
        MSHookMessageEx(inserter, NSSelectorFromString(@"syncHandleCommandMessage:inInbox:reason:context:countMap:"),
                        (IMP)&hook_syncCmd, (IMP*)&orig_syncCmd);
        MSHookMessageEx(inserter, NSSelectorFromString(@"handleCommandMessage:inInbox:reason:context:"),
                        (IMP)&hook_handleCmd, (IMP*)&orig_handleCmd);
        MSHookMessageEx(inserter, NSSelectorFromString(@"syncInsertMessages:conversationExtraMap:inInbox:reason:context:"),
                        (IMP)&hook_syncInsert, (IMP*)&orig_syncInsert);
        ypd_log(@"P3 | Inserter 3 probes OK");
    } else {
        ypd_log(@"P3 | Inserter NOT FOUND");
    }

    if (store) {
        MSHookMessageEx(store, NSSelectorFromString(@"clearMessagesInConversation:beforeOrderIndex:completion:"),
                        (IMP)&hook_clearConv, (IMP*)&orig_clearConv);
        MSHookMessageEx(store, NSSelectorFromString(@"clearMessagesWithConversation:calculateSortTimeBlock:completion:"),
                        (IMP)&hook_clearConv2, (IMP*)&orig_clearConv2);
        MSHookMessageEx(store, NSSelectorFromString(@"deleteMessagesByConvIds:completion:"),
                        (IMP)&hook_delByConvIds, (IMP*)&orig_delByConvIds);
        MSHookMessageEx(store, NSSelectorFromString(@"deleteMessagesByMsgIds:completion:"),
                        (IMP)&hook_delByMsgIds, (IMP*)&orig_delByMsgIds);
        ypd_log(@"P3 | Store 4 probes OK");
    } else {
        ypd_log(@"P3 | Store NOT FOUND");
    }
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
        ypd_hook_probes();

        ypd_log(@"=== YPD v0.13 init complete ===");
    }
}
