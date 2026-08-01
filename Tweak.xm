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
    g_logPath = [paths[0] stringByAppendingPathComponent:@"ypd_v0.38.log"];
    [[NSFileManager defaultManager] createFileAtPath:g_logPath contents:nil attributes:nil];
    g_logHandle = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
    [g_logHandle seekToEndOfFile];
    g_logLock = [[NSLock alloc] init];
    ypd_log(@"=== YPD v0.38 probe (filtered) ===");
}

static BOOL ypd_match(NSString *clsName) {
    NSArray *pfx = @[@"TIM", @"BIMM", @"AWEIM", @"IESIM", @"FlowIM", @"EIM", @"IMChat", @"IMSDK", @"Msg", @"Recall"];
    for (NSString *p in pfx) {
        if ([clsName rangeOfString:p].location != NSNotFound) return YES;
    }
    return NO;
}

static void ypd_find_method(NSString *selName) {
    SEL sel = NSSelectorFromString(selName);
    unsigned int cc;
    Class *classes = objc_copyClassList(&cc);
    for (unsigned int i = 0; i < cc; i++) {
        NSString *cn = NSStringFromClass(classes[i]);
        if (!ypd_match(cn)) continue;
        if (class_respondsToSelector(classes[i], sel)) {
            ypd_log(@"  [%@] -%@", cn, selName);
        }
    }
    free(classes);
}

%ctor {
    @autoreleasepool {
        ypd_init_log();
        ypd_log(@"DELAY 8s...");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ypd_log(@"=== onRecallMessage: ===");
            ypd_find_method(@"onRecallMessage:");
            ypd_log(@"=== onRecallMessageWithMessageId: ===");
            ypd_find_method(@"onRecallMessageWithMessageId:");
            ypd_log(@"=== handleRecallMessage: ===");
            ypd_find_method(@"handleRecallMessage:");
            ypd_log(@"=== didReceiveRecallMessage: ===");
            ypd_find_method(@"didReceiveRecallMessage:");
            ypd_log(@"=== updateMessage:status: ===");
            ypd_find_method(@"updateMessage:status:");
            ypd_log(@"=== DONE ===");
        });
    }
}
