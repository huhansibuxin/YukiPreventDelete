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
    g_logPath = [paths[0] stringByAppendingPathComponent:@"ypd_v0.36.log"];
    [[NSFileManager defaultManager] createFileAtPath:g_logPath contents:nil attributes:nil];
    g_logHandle = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
    [g_logHandle seekToEndOfFile];
    g_logLock = [[NSLock alloc] init];
    ypd_log(@"=== YPD v0.36 ===");
}

static void ypd_swallow_soft_del_1(id self, SEL _cmd, id msg, id conv, BOOL send, id cb) {
    ypd_log(@"BLOCKED | softDeleteMessage:inConversation:sendToServer:completion:");
}

static void ypd_swallow_soft_del_2(id self, SEL _cmd, id msg, id srvMsgID, id conv, id convID, BOOL send, id cb) {
    ypd_log(@"BLOCKED | softDeleteMessage:serverMessageID:inConversation:conversationID:sendToServer:completion:");
}

%ctor {
    @autoreleasepool {
        ypd_init_log();

        Class deleter = NSClassFromString(@"TIMXMessageDeleter");
        if (deleter) {
            MSHookMessageEx(deleter, NSSelectorFromString(@"softDeleteMessage:inConversation:sendToServer:completion:"),
                            (IMP)&ypd_swallow_soft_del_1, NULL);
            MSHookMessageEx(deleter, NSSelectorFromString(@"softDeleteMessage:serverMessageID:inConversation:conversationID:sendToServer:completion:"),
                            (IMP)&ypd_swallow_soft_del_2, NULL);
            ypd_log(@"HOOK | TIMXMessageDeleter softDelete OK");
        } else {
            ypd_log(@"HOOK | TIMXMessageDeleter not found");
        }

        ypd_log(@"=== YPD v0.36 init ===");
    }
}
