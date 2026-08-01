#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/runtime.h>

static NSMutableSet *hookedSelectors;

static void ypd_generic_block(id self, SEL _cmd) {
    NSLog(@"[YPD] BLOCKED %@ %@", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
}

%ctor {
    @autoreleasepool {
        hookedSelectors = [NSMutableSet set];
        unsigned int classCount;
        Class *classes = objc_copyClassList(&classCount);

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

                NSString *key = [NSString stringWithFormat:@"%@_%@", className, selName];
                if ([hookedSelectors containsObject:key]) continue;
                [hookedSelectors addObject:key];

                IMP imp = class_getMethodImplementation(classes[i], sel);
                // Only hook if the method is implemented (not inherited from NSObject)
                Method m = class_getInstanceMethod(classes[i], sel);
                if (!m) continue;

                NSLog(@"[YPD] HOOKING: %@ %@", className, selName);
                MSHookMessageEx(classes[i], sel, (IMP)&ypd_generic_block, NULL);
            }
            free(methods);
        }
        free(classes);
        NSLog(@"[YPD] Total delete methods hooked: %lu", (unsigned long)hookedSelectors.count);
    }
}
