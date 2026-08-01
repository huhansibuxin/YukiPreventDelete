#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <sqlite3.h>

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

static void ypd_init_log(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    g_logPath = [paths[0] stringByAppendingPathComponent:@"ypd_v0.39.log"];
    [[NSFileManager defaultManager] createFileAtPath:g_logPath contents:nil attributes:nil];
    g_logHandle = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
    [g_logHandle seekToEndOfFile];
    g_logLock = [[NSLock alloc] init];
    ypd_log(@"=== YPD v0.39 sqlite3_step probe ===");
}

static int (*orig_sqlite3_step)(sqlite3_stmt*);

static int hooked_sqlite3_step(sqlite3_stmt *stmt) {
    const char *sql = sqlite3_sql(stmt);
    if (sql) {
        NSString *s = [NSString stringWithUTF8String:sql];
        if ([s rangeOfString:@"TIMMessage" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [s rangeOfString:@"deleted" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [s rangeOfString:@"recall" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [s rangeOfString:@"IESIM" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [s rangeOfString:@"AWEIM" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            ypd_log(@"SQL: %@", s);
        }
    }
    return orig_sqlite3_step(stmt);
}

%ctor {
    @autoreleasepool {
        ypd_init_log();
        ypd_log(@"hooking sqlite3_step...");
        void *sym = dlsym(RTLD_DEFAULT, "sqlite3_step");
        if (sym) {
            MSHookFunction(sym, (void*)hooked_sqlite3_step, (void**)&orig_sqlite3_step);
            ypd_log(@"sqlite3_step hooked OK (MSHookFunction)");
        } else {
            ypd_log(@"FAILED: dlsym sqlite3_step returned NULL");
        }
    }
}
