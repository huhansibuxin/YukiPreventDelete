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
    g_logPath = [paths[0] stringByAppendingPathComponent:@"ypd_v0.27.log"];
    [[NSFileManager defaultManager] createFileAtPath:g_logPath contents:nil attributes:nil];
    g_logHandle = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
    [g_logHandle seekToEndOfFile];
    g_logLock = [[NSLock alloc] init];
    ypd_log(@"=== YPD v0.20 ===");
}

// ---- Phase 1 ----
static void hook_delMsg_sc(id self, SEL _cmd, id msg, BOOL send, id comp) {}
static void hook_delMsg_ss(id self, SEL _cmd, id msg, BOOL send) {}
static void hook_delMsgInMem(id self, SEL _cmd, id msg) {}
static void hook_delMsgInMem_sr(id self, SEL _cmd, id msg, BOOL reload) {}
static void hook_batchDel(id self, SEL _cmd, id arr) {}

// ---- Phase 2 ----
static void ypd_block_void(id self, SEL _cmd) {}

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
        NSString *cname = NSStringFromClass(classes[i]);
        if (!ypd_should_scan_class(cname)) continue;
        classCount2++;
        unsigned int mc;
        Method *methods = class_copyMethodList(classes[i], &mc);
        for (unsigned int j = 0; j < mc; j++) {
            SEL sel = method_getName(methods[j]);
            NSString *sn = NSStringFromSelector(sel);
            if (![sn.lowercaseString containsString:@"delete"]) continue;
            NSString *key = [NSString stringWithFormat:@"%@|%@", cname, sn];
            if ([hooked containsObject:key]) continue;
            Method m = class_getInstanceMethod(classes[i], sel);
            if (!m) continue;
            const char *types = method_getTypeEncoding(m);
            if (!types) continue;
            if (types[0] != 'v') continue;
            [hooked addObject:key];
            MSHookMessageEx(classes[i], sel, (IMP)&ypd_block_void, NULL);
            voidCount++;
        }
        free(methods);
    }
    free(classes);
    ypd_log(@"SCAN | %lu classes, %lu BLOCKED", (unsigned long)classCount2, (unsigned long)voidCount);
}

// ---- Phase 3 ----

static NSString *g_backupDir;
static NSString *g_imDir;
static BOOL g_restoring = NO;

static NSString *ypd_docs() {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
}

static void ypd_backup_db() {
    if (g_restoring) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:g_backupDir error:nil];
    [fm createDirectoryAtPath:g_backupDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSArray *files = [fm contentsOfDirectoryAtPath:g_imDir error:nil];
    NSUInteger count = 0;
    for (NSString *f in files) {
        if (![f hasSuffix:@".sqlite"] && ![f hasSuffix:@"-wal"] && ![f hasSuffix:@"-shm"]) continue;
        if ([fm copyItemAtPath:[g_imDir stringByAppendingPathComponent:f] toPath:[g_backupDir stringByAppendingPathComponent:f] error:nil]) count++;
    }
    ypd_log(@"BACKUP | %lu files", (unsigned long)count);
}

static void ypd_restore_files() {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:g_backupDir error:nil];
    NSUInteger count = 0;
    for (NSString *f in files) {
        NSString *src = [g_backupDir stringByAppendingPathComponent:f];
        NSString *dst = [g_imDir stringByAppendingPathComponent:f];
        [fm removeItemAtPath:dst error:nil];
        if ([fm copyItemAtPath:src toPath:dst error:nil]) count++;
    }
    ypd_log(@"RESTORE | %lu files", (unsigned long)count);
}

static void ypd_clear_store_cache(id store) {
    if (!store) { ypd_log(@"CACHE | store nil"); return; }

    // Method 1: cleanDatabaseCache
    SEL cacheSel = NSSelectorFromString(@"dbDouYin_cleanDatabaseCache");
    if ([store respondsToSelector:cacheSel]) {
        @try {
            [store performSelector:cacheSel];
            ypd_log(@"CACHE | cleanDatabaseCache OK");
        } @catch (NSException *e) {
            ypd_log(@"CACHE | cleanDatabaseCache EXCEPTION: %@", e);
        }
    } else {
        ypd_log(@"CACHE | cleanDatabaseCache not found");
    }

    // Method 2: closeDatabaseForUser:completion: — close all connections
    SEL closeSel = NSSelectorFromString(@"dbDouYin_closeDatabaseForUser:completion:");
    if ([store respondsToSelector:closeSel]) {
        @try {
            // Try with current user ID or empty
            [store performSelector:closeSel withObject:@(99000829096) withObject:nil];
            ypd_log(@"CACHE | closeDatabaseForUser OK");
        } @catch (NSException *e) {
            ypd_log(@"CACHE | closeDatabaseForUser EXCEPTION: %@", e);
        }
    }

    // Method 3: setupDatabaseWithUserID: — reinit
    SEL setupSel = NSSelectorFromString(@"dbDouYin_setupDatabaseWithUserID:");
    if ([store respondsToSelector:setupSel]) {
        @try {
            [store performSelector:setupSel withObject:@(99000829096)];
            ypd_log(@"CACHE | setupDatabase OK");
        } @catch (NSException *e) {
            ypd_log(@"CACHE | setupDatabase EXCEPTION: %@", e);
        }
    }
}

static void (*orig_handleDelConv)(id, SEL, id);
static void hook_handleDelConv(id self, SEL _cmd, id ctx) {
    ypd_log(@"TRIGGER");
    if (g_restoring) { ypd_log(@"TRIGGER | skip"); return; }
    g_restoring = YES;

    ypd_restore_files();

    id store = nil;
    @try { store = [self valueForKey:@"db"]; } @catch (NSException *e) {
        ypd_log(@"TRIGGER | self.db EXCEPTION: %@", e);
    }
    ypd_clear_store_cache(store);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ypdMessageReload" object:nil];
        g_restoring = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ypd_backup_db();
        });
    });
}

%ctor {
    @autoreleasepool {
        ypd_init_log();

        Class msgDC = NSClassFromString(@"AWEIMNewMessageDataController");
        if (msgDC) {
            MSHookMessageEx(msgDC, NSSelectorFromString(@"deleteMessage:sendToServer:completion:"), (IMP)&hook_delMsg_sc, NULL);
            MSHookMessageEx(msgDC, NSSelectorFromString(@"deleteMessage:sendToServer:"), (IMP)&hook_delMsg_ss, NULL);
            MSHookMessageEx(msgDC, NSSelectorFromString(@"deleteMessageInMemory:"), (IMP)&hook_delMsgInMem, NULL);
            MSHookMessageEx(msgDC, NSSelectorFromString(@"deleteMessageInMemory:shouldReload:"), (IMP)&hook_delMsgInMem_sr, NULL);
            MSHookMessageEx(msgDC, NSSelectorFromString(@"batchDeleteMessageIds:"), (IMP)&hook_batchDel, NULL);
            ypd_log(@"P1 | NewMsgDC 5 OK");
        }

        ypd_scan_void_delete();

        NSString *docs = ypd_docs();
        g_imDir = [docs stringByAppendingPathComponent:@"TIMXSDKWorkplace/ChatFiles/99000829096"];
        g_backupDir = [docs stringByAppendingPathComponent:@"ypd_db_backup"];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ypd_backup_db();
        });

        Class handler = NSClassFromString(@"TIMXCommandMessageHandler");
        if (handler) {
            MSHookMessageEx(handler, NSSelectorFromString(@"handleDeleteConversationWithContext:"),
                            (IMP)&hook_handleDelConv, (IMP*)&orig_handleDelConv);
            ypd_log(@"P3 | trigger HOOKED");
        }

        ypd_log(@"=== YPD v0.27 init complete ===");
    }
}
