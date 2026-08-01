#import <substrate.h>
#import <dlfcn.h>
#import <sqlite3.h>
#import <Foundation/Foundation.h>

// ============================================================
// YPD v0.16 - sqlite3_step hook
// Strategy: MSHookFunction sqlite3_step, block any modification
// to TIMMessageORM / FTS tables that sets deleted flag or deletes rows.
// This is at the SQLite C layer, before WCDB touches the DB.
// ============================================================

static int (*orig_sqlite3_step)(sqlite3_stmt*);

static inline int ypd_contains(const char *haystack, const char *needle) {
    return strstr(haystack, needle) != NULL;
}

static BOOL should_block(const char *sql) {
    if (sql == NULL) return NO;

    if (ypd_contains(sql, "TIMMessageORM")) {
        if (ypd_contains(sql, "deleted") || ypd_contains(sql, "DELETE")) {
            return YES;
        }
    }
    if (ypd_contains(sql, "IESIMFTSUserData") || ypd_contains(sql, "AWEIMFTSSyncMessageData")) {
        if (ypd_contains(sql, "deleted") || ypd_contains(sql, "DELETE") || ypd_contains(sql, "remove")) {
            return YES;
        }
    }
    return NO;
}

static int hooked_sqlite3_step(sqlite3_stmt *stmt) {
    const char *sql = sqlite3_sql(stmt);
    
    if (should_block(sql)) {
        NSLog(@"YPD_v016 | BLOCKED sql: %s", sql);
        return 101; // SQLITE_DONE — caller thinks statement completed successfully
    }
    
    return orig_sqlite3_step(stmt);
}

%ctor {
    MSHookFunction((void *)sqlite3_step, (void *)hooked_sqlite3_step, (void **)&orig_sqlite3_step);
    
    NSLog(@"YPD_v016 | sqlite3_step hooked");
    NSLog(@"=== YPD v0.16 init ===");
}
