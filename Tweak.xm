#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ── DEBUG ──
#define YPD_LOG(fmt, ...) \
    do { \
        NSString *_log = [NSString stringWithFormat:@"[YPD] " fmt, ##__VA_ARGS__]; \
        printf("%s\n", _log.UTF8String); \
        if (YPD_LOG_BUFFER) { [YPD_LOG_BUFFER addObject:_log]; if (YPD_LOG_BUFFER.count > 200) [YPD_LOG_BUFFER removeObjectAtIndex:0]; } \
    } while(0)

static NSMutableArray<NSString *> *YPD_LOG_BUFFER = nil;

// ── PREFERENCES ──
static inline BOOL YPD_Enabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"YPD_Enabled"] ?: YES;
}
static inline BOOL YPD_PreventRemoteDelete(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"YPD_PreventRemoteDelete"] ?: YES;
}

// ── LOCAL DELETE FLAG ──
// 本端主动删除时设置标记，放行本端操作，拦截远端推送
static BOOL YPD_IsLocalDeleteInProgress = NO;
static NSInteger YPD_LocalDeleteGuardCounter = 0;

// ── SAVED IMPS ──
static IMP YPD_Orig_MsgDeleted = NULL;
static IMP YPD_Orig_BatchMessagesDeleted = NULL;

// ──────────────────────────────────────────────
//  策略 A：数据层 IESIMChatDataManagerDelegate
// ──────────────────────────────────────────────

// iesim_messageDeleted:inConversation:reason:
static void YPD_Hook_MsgDeleted(id self, SEL _cmd, NSString *msgID, NSString *convID, NSString *reason)
{
    if (YPD_Enabled() && YPD_PreventRemoteDelete() && !YPD_IsLocalDeleteInProgress) {
        YPD_LOG(@"[BLOCKED] remote delete msg=%@ conv=%@ reason=%@", msgID, convID, reason);
        return;
    }
    YPD_LOG(@"[PASS] local delete msg=%@ conv=%@ reason=%@", msgID, convID, reason);
    if (YPD_Orig_MsgDeleted) {
        ((void(*)(id, SEL, NSString*, NSString*, NSString*))YPD_Orig_MsgDeleted)(self, _cmd, msgID, convID, reason);
    }
}

// iesim_onConversationDataSourceMessagesDeleted:belongingConversationMap:
static void YPD_Hook_BatchMessagesDeleted(id self, SEL _cmd, NSArray *msgIdentifiers, NSDictionary *belongingConvMap)
{
    if (YPD_Enabled() && YPD_PreventRemoteDelete() && !YPD_IsLocalDeleteInProgress) {
        YPD_LOG(@"[BLOCKED] remote batch delete msgs=%@ map=%@", msgIdentifiers, belongingConvMap);
        return;
    }
    YPD_LOG(@"[PASS] local batch delete msgs=%@ map=%@", msgIdentifiers, belongingConvMap);
    if (YPD_Orig_BatchMessagesDeleted) {
        ((void(*)(id, SEL, NSArray*, NSDictionary*))YPD_Orig_BatchMessagesDeleted)(self, _cmd, msgIdentifiers, belongingConvMap);
    }
}

// ──────────────────────────────────────────────
//  运行时查找并 hook delegate 实现类
// ──────────────────────────────────────────────

static void YPD_FindAndHookDelegateClass(void)
{
    Protocol *delegateProto = objc_getProtocol("IESIMChatDataManagerDelegate");
    if (!delegateProto) {
        YPD_LOG(@"ERROR: IESIMChatDataManagerDelegate protocol not found");
        return;
    }

    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    unsigned int hooked = 0;
    for (unsigned int i = 0; i < count; i++) {
        Class c = classes[i];
        if (class_conformsToProtocol(c, delegateProto)) {
            YPD_LOG(@"FOUND delegate class: %s", class_getName(c));

            SEL selSingle = @selector(iesim_messageDeleted:inConversation:reason:);
            Method mSingle = class_getInstanceMethod(c, selSingle);
            if (mSingle) {
                const char *type = method_getTypeEncoding(mSingle);
                YPD_Orig_MsgDeleted = class_replaceMethod(c, selSingle, (IMP)YPD_Hook_MsgDeleted, type);
                YPD_LOG(@"  hooked iesim_messageDeleted:inConversation:reason:");
            }

            SEL selBatch = @selector(iesim_onConversationDataSourceMessagesDeleted:belongingConversationMap:);
            Method mBatch = class_getInstanceMethod(c, selBatch);
            if (mBatch) {
                const char *type = method_getTypeEncoding(mBatch);
                YPD_Orig_BatchMessagesDeleted = class_replaceMethod(c, selBatch, (IMP)YPD_Hook_BatchMessagesDeleted, type);
                YPD_LOG(@"  hooked iesim_onConversationDataSourceMessagesDeleted:belongingConversationMap:");
            }
            hooked++;
        }
    }
    free(classes);

    if (hooked == 0) {
        YPD_LOG(@"WARNING: No delegate class found. Delegate might load later.");
    } else {
        YPD_LOG(@"Hooked %u delegate classes successfully.", hooked);
    }
}

// ──────────────────────────────────────────────
//  本端删除标记：安全网自动清除
// ──────────────────────────────────────────────

static void YPD_SetLocalDeleteFlag(void) {
    YPD_IsLocalDeleteInProgress = YES;
    YPD_LocalDeleteGuardCounter++;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        YPD_LocalDeleteGuardCounter--;
        if (YPD_LocalDeleteGuardCounter <= 0) {
            YPD_IsLocalDeleteInProgress = NO;
            YPD_LocalDeleteGuardCounter = 0;
        }
    });
}

// ──────────────────────────────────────────────
//  %ctor
// ──────────────────────────────────────────────

%ctor {
    YPD_LOG_BUFFER = [NSMutableArray array];
    YPD_LOG(@"YukiPreventDelete v0.1 loading...");

    // 延迟执行，等待 AwemeCore + delegate 类完全加载
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        YPD_FindAndHookDelegateClass();
    });
}
