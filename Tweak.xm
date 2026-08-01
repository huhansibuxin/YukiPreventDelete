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
    g_logPath = [paths[0] stringByAppendingPathComponent:@"ypd_v0.6.log"];
    [[NSFileManager defaultManager] createFileAtPath:g_logPath contents:nil attributes:nil];
    g_logHandle = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
    [g_logHandle seekToEndOfFile];
    g_logLock = [[NSLock alloc] init];
    ypd_log(@"=== YPD v0.6 started ===");
}

// ---- Phase 1: AWEIMNewMessageDataController void delete methods ----

static void hook_delMsg_sc(id self, SEL _cmd, id msg, BOOL send, id comp) {
    ypd_log(@"BLOCK | NewMsgDC | deleteMessage:sendToServer:completion: send=%d", send);
}
static void hook_delMsg_ss(id self, SEL _cmd, id msg, BOOL send) {
    ypd_log(@"BLOCK | NewMsgDC | deleteMessage:sendToServer: send=%d", send);
}
static void hook_delMsgInMem(id self, SEL _cmd, id msg) {
    ypd_log(@"BLOCK | NewMsgDC | deleteMessageInMemory:");
}
static void hook_delMsgInMem_sr(id self, SEL _cmd, id msg, BOOL reload) {
    ypd_log(@"BLOCK | NewMsgDC | deleteMessageInMemory:shouldReload: reload=%d", reload);
}
static void hook_batchDel(id self, SEL _cmd, id arr) {
    ypd_log(@"BLOCK | NewMsgDC | batchDeleteMessageIds: count=%lu", (unsigned long)[arr count]);
}

// ---- Phase 2: void delete method blocker (runtime scan, void only) ----

static void ypd_block_void(id self, SEL _cmd) {
    ypd_log(@"BLOCK | %@ | %@", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
}

// ---- Phase 3: BOOL-returning sync delete methods - return NO to block ----

static BOOL hook_syncDeleteIndexRange(id self, SEL _cmd, id conversation) {
    ypd_log(@"BLOCK | TIMXNewMsgStore | syncDeleteIndexRangeInConversation:");
    return NO;
}
static BOOL hook_internal_syncDeleteMessages(id self, SEL _cmd, id conversationIDs) {
    ypd_log(@"BLOCK | TIMXNewMsgStore | internal_syncDeleteMessagesWithConversationIdentifiers:");
    return NO;
}
static BOOL hook_syncBatchDeleteConvMessages(id self, SEL _cmd, id stuff) {
    ypd_log(@"BLOCK | TIMXNewMsgStore | syncBatchDeleteConversationMessages:");
    return NO;
}
static BOOL hook_syncBatchDeleteConvInfos(id self, SEL _cmd, id infos, id options, id db) {
    ypd_log(@"BLOCK | TIMXNewMsgStore | syncBatchDeleteConversationInfos:options:conversationDB:");
    return NO;
}
static BOOL hook_internal_syncBatchDeleteOtherInfo(id self, SEL _cmd, id convIDs) {
    ypd_log(@"BLOCK | TIMXNewMsgStore | internal_syncBatchDeleteConversationsOtherInfoWithConversationIdentifiers:");
    return NO;
}

// ---- Phase 2 (scan) implementation ----

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
            if (types[0] != 'v') continue; // void only
            
            [hooked addObject:key];
            MSHookMessageEx(classes[i], sel, (IMP)&ypd_block_void, NULL);
            voidCount++;
        }
        free(methods);
    }
    free(classes);
    ypd_log(@"SCAN | %lu void delete methods hooked", (unsigned long)voidCount);
}

%ctor {
    @autoreleasepool {
        ypd_init_log();

        // Phase 1: AWEIMNewMessageDataController
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

        // Phase 2: scan all void delete methods
        ypd_scan_void_delete();

        // Phase 3: BOOL-returning sync delete methods
        Class store = NSClassFromString(@"TIMXNewMessageStore");
        if (store) {
            MSHookMessageEx(store, NSSelectorFromString(@"syncDeleteIndexRangeInConversation:"), (IMP)&hook_syncDeleteIndexRange, NULL);
            MSHookMessageEx(store, NSSelectorFromString(@"internal_syncDeleteMessagesWithConversationIdentifiers:"), (IMP)&hook_internal_syncDeleteMessages, NULL);
            MSHookMessageEx(store, NSSelectorFromString(@"syncBatchDeleteConversationMessages:"), (IMP)&hook_syncBatchDeleteConvMessages, NULL);
            MSHookMessageEx(store, NSSelectorFromString(@"syncBatchDeleteConversationInfos:options:conversationDB:"), (IMP)&hook_syncBatchDeleteConvInfos, NULL);
            MSHookMessageEx(store, NSSelectorFromString(@"internal_syncBatchDeleteConversationsOtherInfoWithConversationIdentifiers:"), (IMP)&hook_internal_syncBatchDeleteOtherInfo, NULL);
            ypd_log(@"P3 | TIMXNewMsgStore 5 sync BOOL hooks OK");
        } else {
            ypd_log(@"P3 | TIMXNewMessageStore NOT FOUND");
        }

        ypd_log(@"=== YPD v0.6 init complete ===");
    }
}
