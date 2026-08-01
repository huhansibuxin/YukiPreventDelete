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

static void ypd_init_log(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    g_logPath = [paths[0] stringByAppendingPathComponent:@"ypd_v0.34.log"];
    [[NSFileManager defaultManager] createFileAtPath:g_logPath contents:nil attributes:nil];
    g_logHandle = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
    [g_logHandle seekToEndOfFile];
    g_logLock = [[NSLock alloc] init];
    ypd_log(@"=== YPD v0.34 probe ===");
}

static void hook_handleDelConv(id self, SEL _cmd, id ctx) {
    ypd_log(@"=== handleDeleteConversationWithContext HIT ===");
    ypd_log(@"STACK:\n%@", [NSThread callStackSymbols]);
}

static void ypd_scan_methods(void) {
    unsigned int classCount;
    Class *classes = objc_copyClassList(&classCount);
    for (unsigned int i = 0; i < classCount; i++) {
        NSString *cname = NSStringFromClass(classes[i]);
        if (![cname hasPrefix:@"TIM"]) continue;
        if ([cname rangeOfString:@"Delete"].location == NSNotFound &&
            [cname rangeOfString:@"delete"].location == NSNotFound) continue;
        ypd_log(@"CLASS: %@", cname);
        unsigned int mc;
        Method *methods = class_copyMethodList(classes[i], &mc);
        for (unsigned int j = 0; j < mc; j++) {
            SEL sel = method_getName(methods[j]);
            ypd_log(@"  - %@", NSStringFromSelector(sel));
        }
        free(methods);
    }
    free(classes);
}

%ctor {
    @autoreleasepool {
        ypd_init_log();
        ypd_log(@"DELAY 6s for app init...");

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ypd_scan_methods();

            Class handler = NSClassFromString(@"TIMXCommandMessageHandler");
            if (handler) {
                ypd_log(@"=== TIMXCommandMessageHandler all methods ===");
                unsigned int mc;
                Method *methods = class_copyMethodList(handler, &mc);
                for (unsigned int j = 0; j < mc; j++) {
                    SEL sel = method_getName(methods[j]);
                    ypd_log(@"  - %@", NSStringFromSelector(sel));
                }
                free(methods);

                MSHookMessageEx(handler, NSSelectorFromString(@"handleDeleteConversationWithContext:"),
                                (IMP)&hook_handleDelConv, NULL);
                ypd_log(@"HOOK OK");
            } else {
                ypd_log(@"TIMXCommandMessageHandler not found");
            }
        });
    }
}
