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
    g_logPath = [paths[0] stringByAppendingPathComponent:@"ypd_v0.37.log"];
    [[NSFileManager defaultManager] createFileAtPath:g_logPath contents:nil attributes:nil];
    g_logHandle = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
    [g_logHandle seekToEndOfFile];
    g_logLock = [[NSLock alloc] init];
    ypd_log(@"=== YPD v0.37 probe ===");
}

static void ypd_find_method(NSString *selName) {
    SEL sel = NSSelectorFromString(selName);
    unsigned int cc;
    Class *classes = objc_copyClassList(&cc);
    for (unsigned int i = 0; i < cc; i++) {
        Class cls = classes[i];
        if (class_respondsToSelector(cls, sel)) {
            ypd_log(@"HAS [%@] %@", selName, NSStringFromClass(cls));
        }
    }
    free(classes);
}

static void ypd_find_protocol(void) {
    Protocol *proto = NSProtocolFromString(@"BIMMessageListener");
    if (!proto) { ypd_log(@"BIMMessageListener protocol not found"); return; }
    unsigned int cc;
    Class *classes = objc_copyClassList(&cc);
    for (unsigned int i = 0; i < cc; i++) {
        if (class_conformsToProtocol(classes[i], proto)) {
            ypd_log(@"CONFORMS BIMMessageListener: %@", NSStringFromClass(classes[i]));
        }
    }
    free(classes);
}

static void ypd_find_all_recall(void) {
    unsigned int cc;
    Class *classes = objc_copyClassList(&cc);
    for (unsigned int i = 0; i < cc; i++) {
        unsigned int mc;
        Method *methods = class_copyMethodList(classes[i], &mc);
        for (unsigned int j = 0; j < mc; j++) {
            NSString *sn = NSStringFromSelector(method_getName(methods[j]));
            if ([sn containsString:@"Recall"] || [sn containsString:@"recall"]) {
                ypd_log(@"RECALL | %@ -%@", NSStringFromClass(classes[i]), sn);
            }
        }
        free(methods);
    }
    free(classes);
}

%ctor {
    @autoreleasepool {
        ypd_init_log();
        ypd_log(@"DELAY 8s...");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ypd_log(@"=== Searching onRecallMessage: ===");
            ypd_find_method(@"onRecallMessage:");
            ypd_log(@"=== Searching onRecallMessageWithMessageId: ===");
            ypd_find_method(@"onRecallMessageWithMessageId:");
            ypd_log(@"=== Searching updateMessage:status: ===");
            ypd_find_method(@"updateMessage:status:");
            ypd_log(@"=== Searching handleRecallMessage: ===");
            ypd_find_method(@"handleRecallMessage:");
            ypd_log(@"=== BIMMessageListener protocol ===");
            ypd_find_protocol();
            ypd_log(@"=== All Recall methods ===");
            ypd_find_all_recall();
            ypd_log(@"=== YPD v0.37 done ===");
        });
    }
}
