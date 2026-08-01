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

static void ypd_generic_block(id self, SEL _cmd) {
    ypd_log(@"BLOCKED | %@ | %@", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
}

%ctor {
    @autoreleasepool {
        // Setup log file in Douyin's tmp dir
        NSString *tmpDir = NSTemporaryDirectory();
        g_logPath = [tmpDir stringByAppendingPathComponent:@"ypd_v0.4.log"];
        [[NSFileManager defaultManager] createFileAtPath:g_logPath contents:nil attributes:nil];
        g_logHandle = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
        [g_logHandle seekToEndOfFile];
        g_logLock = [[NSLock alloc] init];

        ypd_log(@"=== YukiPreventDelete v0.4 started ===");
        ypd_log(@"Log path: %@", g_logPath);

        unsigned int classCount;
        Class *classes = objc_copyClassList(&classCount);
        NSMutableSet *hooked = [NSMutableSet set];
        NSUInteger hookCount = 0;

        for (unsigned int i = 0; i < classCount; i++) {
            NSString *className = NSStringFromClass(classes[i]);
            if (![className containsString:@"EIM"] &&
                ![className containsString:@"Message"] &&
                ![className containsString:@"Chat"] &&
                ![className containsString:@"FlowIM"]) continue;

            unsigned int methodCount;
            Method *methods = class_copyMethodList(classes[i], &methodCount);
            for (unsigned int j = 0; j < methodCount; j++) {
                SEL sel = method_getName(methods[j]);
                NSString *selName = NSStringFromSelector(sel);
                if (![selName.lowercaseString containsString:@"delete"]) continue;

                NSString *key = [NSString stringWithFormat:@"%@|%@", className, selName];
                if ([hooked containsObject:key]) continue;
                [hooked addObject:key];

                Method m = class_getInstanceMethod(classes[i], sel);
                if (!m) continue;

                ypd_log(@"HOOK | %@ | %@", className, selName);
                MSHookMessageEx(classes[i], sel, (IMP)&ypd_generic_block, NULL);
                hookCount++;
            }
            free(methods);
        }
        free(classes);
        ypd_log(@"=== Hook complete: %lu methods hooked ===", (unsigned long)hookCount);
    }
}
