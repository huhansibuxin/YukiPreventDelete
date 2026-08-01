#import <Foundation/Foundation.h>
#import <substrate.h>
#import <dlfcn.h>

static NSString *g_logPath;
static NSFileHandle *g_logHandle;
static NSLock *g_logLock;
static NSString *g_imDir = nil;

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

static void ypd_init_log(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    g_logPath = [paths[0] stringByAppendingPathComponent:@"ypd_v0.30.log"];
    [[NSFileManager defaultManager] createFileAtPath:g_logPath contents:nil attributes:nil];
    g_logHandle = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
    [g_logHandle seekToEndOfFile];
    g_logLock = [[NSLock alloc] init];
    ypd_log(@"=== YPD v0.30 ===");
}

static void *g_libsqlite3 = NULL;
static int (*g_sqlite3_open)(const char *, void **) = NULL;
static int (*g_sqlite3_exec)(void *, const char *, int, void *, char **) = NULL;
static int (*g_sqlite3_close)(void *) = NULL;
static const char *(*g_sqlite3_errmsg)(void *) = NULL;

static void ypd_init_sqlite3(void) {
    if (g_libsqlite3) return;
    g_libsqlite3 = dlopen("/usr/lib/libsqlite3.dylib", RTLD_NOW);
    if (!g_libsqlite3) { ypd_log(@"SQLITE | dlopen failed"); return; }
    g_sqlite3_open = (typeof(g_sqlite3_open))dlsym(g_libsqlite3, "sqlite3_open");
    g_sqlite3_exec = (typeof(g_sqlite3_exec))dlsym(g_libsqlite3, "sqlite3_exec");
    g_sqlite3_close = (typeof(g_sqlite3_close))dlsym(g_libsqlite3, "sqlite3_close");
    g_sqlite3_errmsg = (typeof(g_sqlite3_errmsg))dlsym(g_libsqlite3, "sqlite3_errmsg");
    ypd_log(@"SQLITE | symbols OK");
}

static void ypd_fix_deleted(void) {
    if (!g_sqlite3_open || !g_sqlite3_exec || !g_sqlite3_close) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:g_imDir error:nil];
    for (NSString *f in files) {
        NSString *ext = [f pathExtension];
        if (![ext isEqualToString:@"sqlite"]) continue;
        NSString *full = [g_imDir stringByAppendingPathComponent:f];
        void *db = NULL;
        int rc = g_sqlite3_open([full UTF8String], &db);
        if (rc != 0) {
            ypd_log(@"SQLITE | open %@ failed: %d", f, rc);
            continue;
        }
        char *err = NULL;
        rc = g_sqlite3_exec(db, "UPDATE TIMMessageORM SET deleted=0", 0, 0, &err);
        if (rc != 0) {
            ypd_log(@"SQLITE | UPDATE %@ failed: %s", f, err);
        } else {
            ypd_log(@"SQLITE | %@ deleted=0 OK", f);
        }
        g_sqlite3_close(db);
    }
}

static NSString *g_backupDir;
static BOOL g_restoring = NO;

static void ypd_backup_db(void) {
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

static void ypd_restore_files(void) {
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

    SEL cacheSel = NSSelectorFromString(@"dbDouYin_cleanDatabaseCache");
    if ([store respondsToSelector:cacheSel]) {
        [store performSelector:cacheSel];
        ypd_log(@"CACHE | cleanDatabaseCache OK");
    }

    SEL closeSel = NSSelectorFromString(@"dbDouYin_closeDatabaseForUser:completion:");
    if ([store respondsToSelector:closeSel]) {
        [store performSelector:closeSel withObject:@(99000829096) withObject:nil];
        ypd_log(@"CACHE | closeDatabaseForUser OK");
    }

    SEL setupSel = NSSelectorFromString(@"dbDouYin_setupDatabaseWithUserID:");
    if ([store respondsToSelector:setupSel]) {
        [store performSelector:setupSel withObject:@(99000829096)];
        ypd_log(@"CACHE | setupDatabase OK");
    }
}

static void (*orig_handleDelConv)(id, SEL, id);
static void hook_handleDelConv(id self, SEL _cmd, id ctx) {
    ypd_log(@"TRIGGER");
    if (g_restoring) { ypd_log(@"TRIGGER | skip"); return; }
    g_restoring = YES;

    ypd_restore_files();
    ypd_fix_deleted();

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
        ypd_init_sqlite3();

        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
        g_imDir = [docs stringByAppendingPathComponent:@"TIMXSDKWorkplace/ChatFiles/99000829096"];
        g_backupDir = [docs stringByAppendingPathComponent:@"ypd_db_backup"];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ypd_backup_db();
        });

        Class handler = NSClassFromString(@"TIMXCommandMessageHandler");
        if (handler) {
            MSHookMessageEx(handler, NSSelectorFromString(@"handleDeleteConversationWithContext:"),
                            (IMP)&hook_handleDelConv, (IMP*)&orig_handleDelConv);
            ypd_log(@"HOOK | handleDeleteConversationWithContext OK");
        } else {
            ypd_log(@"HOOK | TIMXCommandMessageHandler not found");
        }

        ypd_log(@"=== YPD v0.30 init ===");
    }
}
