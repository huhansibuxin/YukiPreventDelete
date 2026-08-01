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
    g_logPath = [paths[0] stringByAppendingPathComponent:@"ypd_v0.15.log"];
    [[NSFileManager defaultManager] createFileAtPath:g_logPath contents:nil attributes:nil];
    g_logHandle = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
    [g_logHandle seekToEndOfFile];
    g_logLock = [[NSLock alloc] init];
    ypd_log(@"=== YPD v0.15 ===");
}

// ---- Phase 1 ----

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

// ---- Phase 3: DB snapshot + restore with WCDB reopen ----

static NSString *g_backupDir;
static NSString *g_imDir;
static BOOL g_backupDone = NO;
static BOOL g_restoring = NO;
static id g_storeInstance = nil;

static NSString *ypd_docs() {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
}

static id ypd_get_store() {
    if (g_storeInstance) return g_storeInstance;
    Class store = NSClassFromString(@"TIMXNewMessageStore");
    if (!store) return nil;
    // try sharedInstance / defaultStore / sharedStore
    for (NSString *selName in @[@"sharedInstance", @"sharedStore", @"defaultStore", @"store"]) {
        SEL sel = NSSelectorFromString(selName);
        if ([store respondsToSelector:sel]) {
            id inst = [store performSelector:sel];
            if (inst) { g_storeInstance = inst; return inst; }
        }
    }
    ypd_log(@"WCDB | TIMXNewMessageStore found but no singleton accessor");
    return nil;
}

static id ypd_get_database(id store) {
    // Try common WCDB property names
    for (NSString *key in @[@"database", @"db", @"wctDatabase", @"wcdb", @"dataBase"]) {
        @try { id db = [store valueForKey:key]; if (db) return db; }
        @catch (NSException *e) {}
    }
    return nil;
}

static void ypd_close_db(id db) {
    // Try close / closeDatabase
    for (NSString *selName in @[@"close", @"closeDatabase", @"close:"]) {
        SEL sel = NSSelectorFromString(selName);
        @try {
            if ([db respondsToSelector:sel]) {
                [db performSelector:sel];
                ypd_log(@"WCDB | called %@ OK", selName);
                return;
            }
        }
        @catch (NSException *e) {
            ypd_log(@"WCDB | %@ threw: %@", selName, e);
        }
    }
    ypd_log(@"WCDB | no close method found on %@", NSStringFromClass([db class]));
}

static void ypd_reopen_db(id db) {
    // Try open / openDatabase
    for (NSString *selName in @[@"open", @"openDatabase"]) {
        SEL sel = NSSelectorFromString(selName);
        @try {
            if ([db respondsToSelector:sel]) {
                [db performSelector:sel];
                ypd_log(@"WCDB | called %@ OK", selName);
                return;
            }
        }
        @catch (NSException *e) {
            ypd_log(@"WCDB | %@ threw: %@", selName, e);
        }
    }
    ypd_log(@"WCDB | no open method found");
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
        NSString *src = [g_imDir stringByAppendingPathComponent:f];
        NSString *dst = [g_backupDir stringByAppendingPathComponent:f];
        if ([fm copyItemAtPath:src toPath:dst error:nil]) count++;
    }
    g_backupDone = YES;
    ypd_log(@"BACKUP | %lu files", (unsigned long)count);
}

static void ypd_restore_and_reopen() {
    if (g_restoring) return;
    g_restoring = YES;
    ypd_log(@"RESTORE | restoring files");

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

    // Close & reopen WCDB
    id store = ypd_get_store();
    if (store) {
        id db = ypd_get_database(store);
        if (db) {
            ypd_log(@"WCDB | found database: %@", NSStringFromClass([db class]));
            ypd_close_db(db);
            // Small delay for WAL checkpoint
            [NSThread sleepForTimeInterval:0.5];
            ypd_reopen_db(db);
        } else {
            ypd_log(@"WCDB | no database property found on store");
        }
    } else {
        ypd_log(@"WCDB | no store instance found");
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ypdMessageReload" object:nil];
        g_restoring = NO;
        g_backupDone = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ypd_backup_db();
        });
    });
}

static void (*orig_handleDelConv)(id, SEL, id);
static void hook_handleDelConv(id self, SEL _cmd, id ctx) {
    ypd_log(@"TRIGGER | handleDeleteConversationWithContext");
    ypd_restore_and_reopen();
}

static void ypd_setup_restore() {
    Class handler = NSClassFromString(@"TIMXCommandMessageHandler");
    if (handler) {
        MSHookMessageEx(handler, NSSelectorFromString(@"handleDeleteConversationWithContext:"),
                        (IMP)&hook_handleDelConv, (IMP*)&orig_handleDelConv);
        ypd_log(@"P3 | trigger HOOKED");
    }
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

        ypd_setup_restore();

        ypd_log(@"=== YPD v0.15 init complete ===");
    }
}
