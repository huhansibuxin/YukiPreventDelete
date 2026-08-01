#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

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
    g_logPath = [paths[0] stringByAppendingPathComponent:@"ypd_v0.14.log"];
    [[NSFileManager defaultManager] createFileAtPath:g_logPath contents:nil attributes:nil];
    g_logHandle = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
    [g_logHandle seekToEndOfFile];
    g_logLock = [[NSLock alloc] init];
    ypd_log(@"=== YPD v0.14 ===");
}

// ---- Phase 1: AWEIMNewMessageDataController ----

static void hook_delMsg_sc(id self, SEL _cmd, id msg, BOOL send, id comp) {
    ypd_log(@"BLOCK | NewMsgDC | deleteMsg:send:completion:");
}
static void hook_delMsg_ss(id self, SEL _cmd, id msg, BOOL send) {
    ypd_log(@"BLOCK | NewMsgDC | deleteMsg:send:");
}
static void hook_delMsgInMem(id self, SEL _cmd, id msg) {
    ypd_log(@"BLOCK | NewMsgDC | deleteMsgInMemory:");
}
static void hook_delMsgInMem_sr(id self, SEL _cmd, id msg, BOOL reload) {
    ypd_log(@"BLOCK | NewMsgDC | deleteMsgInMemory:shouldReload:");
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

// ---- Phase 3: DB snapshot & restore ----

static NSString *g_backupDir;
static NSString *g_imDir;
static BOOL g_backupDone = NO;
static BOOL g_restoring = NO;

static NSString *ypd_get_app_docs() {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return paths[0];
}

static void ypd_backup_db() {
    if (g_backupDone || g_restoring) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    // clean old backup
    [fm removeItemAtPath:g_backupDir error:nil];
    [fm createDirectoryAtPath:g_backupDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSArray *files = [fm contentsOfDirectoryAtPath:g_imDir error:nil];
    NSUInteger count = 0;
    for (NSString *f in files) {
        if (![f hasSuffix:@".sqlite"] && ![f hasSuffix:@"-wal"] && ![f hasSuffix:@"-shm"]) continue;
        NSString *src = [g_imDir stringByAppendingPathComponent:f];
        NSString *dst = [g_backupDir stringByAppendingPathComponent:f];
        if ([fm copyItemAtPath:src toPath:dst error:nil]) count++;
    }
    g_backupDone = YES;
    ypd_log(@"BACKUP | %lu files to %@", (unsigned long)count, g_backupDir);
}

static void ypd_restore_db() {
    if (g_restoring) return;
    g_restoring = YES;
    ypd_log(@"RESTORE | restoring from %@", g_backupDir);

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:g_backupDir error:nil];
    NSUInteger count = 0;
    for (NSString *f in files) {
        NSString *src = [g_backupDir stringByAppendingPathComponent:f];
        NSString *dst = [g_imDir stringByAppendingPathComponent:f];
        [fm removeItemAtPath:dst error:nil];
        if ([fm copyItemAtPath:src toPath:dst error:nil]) count++;
    }
    ypd_log(@"RESTORE | %lu files restored", (unsigned long)count);

    // Reload conversations
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ypd_log(@"RESTORE | posting reload notification");
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ypdMessageReload" object:nil];
        g_restoring = NO;
        g_backupDone = NO;
        // re-backup after restore
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ypd_backup_db();
        });
    });
}

// Hook handleDeleteConversationWithContext: trigger restore
static void (*orig_handleDelConv)(id, SEL, id);

static void hook_handleDelConv(id self, SEL _cmd, id ctx) {
    ypd_log(@"TRIGGER | handleDeleteConversationWithContext — starting restore");
    // Block original
    ypd_restore_db();
}

static void ypd_setup_restore_trigger() {
    Class handler = NSClassFromString(@"TIMXCommandMessageHandler");
    if (handler) {
        MSHookMessageEx(handler, NSSelectorFromString(@"handleDeleteConversationWithContext:"),
                        (IMP)&hook_handleDelConv, (IMP*)&orig_handleDelConv);
        ypd_log(@"P3 | restore trigger HOOKED");
    } else {
        ypd_log(@"P3 | TIMXCommandMessageHandler NOT FOUND");
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
        }

        ypd_scan_void_delete();

        // Phase 3: DB backup + restore
        NSString *docs = ypd_get_app_docs();
        g_imDir = [docs stringByAppendingPathComponent:@"TIMXSDKWorkplace/ChatFiles/99000829096"];
        g_backupDir = [docs stringByAppendingPathComponent:@"ypd_db_backup"];

        // Backup after 5s (give app time to load conversations)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ypd_backup_db();
        });

        ypd_setup_restore_trigger();

        ypd_log(@"=== YPD v0.14 init complete ===");
    }
}
