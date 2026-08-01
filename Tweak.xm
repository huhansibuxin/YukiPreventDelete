#import <Foundation/Foundation.h>
#import <substrate.h>

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
    g_logPath = [paths[0] stringByAppendingPathComponent:@"ypd_v0.33.log"];
    [[NSFileManager defaultManager] createFileAtPath:g_logPath contents:nil attributes:nil];
    g_logHandle = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
    [g_logHandle seekToEndOfFile];
    g_logLock = [[NSLock alloc] init];
    ypd_log(@"=== YPD v0.33 ===");
}

static void hook_handleDelConv(id self, SEL _cmd, id ctx) {
    ypd_log(@"BLOCKED | handleDeleteConversationWithContext swallowed");
    // 不调用原始实现，直接返回，删除指令不会到达 DB
}

%ctor {
    @autoreleasepool {
        ypd_init_log();

        Class handler = NSClassFromString(@"TIMXCommandMessageHandler");
        if (handler) {
            MSHookMessageEx(handler, NSSelectorFromString(@"handleDeleteConversationWithContext:"),
                            (IMP)&hook_handleDelConv, NULL);
            ypd_log(@"HOOK | handleDeleteConversationWithContext OK");
        } else {
            ypd_log(@"HOOK | TIMXCommandMessageHandler not found");
        }

        ypd_log(@"=== YPD v0.33 init ===");
    }
}
