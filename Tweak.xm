#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ── LOG ──
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

// ── SAVED IMPS FOR RESTORE IF NEEDED ──
static IMP YPD_Orig_DeleteMessages = NULL;
static IMP YPD_Orig_DeleteConversation = NULL;

// ──────────────────────────────────────────────
//  P0: FlowIMChatService.deleteMessagesWithMsgIDs:callBack:
// ──────────────────────────────────────────────

static void YPD_Hook_DeleteMessages(id self, SEL _cmd, NSArray *msgIDs, void (^callback)(NSArray *, id error))
{
    YPD_LOG(@"[BLOCKED] deleteMessagesWithMsgIDs: %lu msgs", (unsigned long)msgIDs.count);
    // 不调原始实现，直接回调空数组表示没有消息被删除
    if (callback) {
        callback(@[], nil);
    }
}

// ──────────────────────────────────────────────
//  P0: FlowIMConversationService.deleteConversationWith:success:fail:
// ──────────────────────────────────────────────

static void YPD_Hook_DeleteConversation(id self, SEL _cmd, NSString *convID, void (^success)(void), void (^fail)(id error))
{
    YPD_LOG(@"[BLOCKED] deleteConversationWith: %@", convID);
    // 不调原始实现，回调 fail 让 UI 知道删除未执行
    // 传 nil error 表示静默失败（UI 不会弹错误提示）
    if (fail) {
        fail(nil);
    }
}

// ──────────────────────────────────────────────
//  策略B：IESIM delegate 回调拦截（兜底）
// ──────────────────────────────────────────────

static IMP YPD_Orig_MsgDeleted = NULL;
static IMP YPD_Orig_BatchDeleted = NULL;

static void YPD_Hook_MsgDeleted(id self, SEL _cmd, NSString *msgID, NSString *convID, NSString *reason)
{
    YPD_LOG(@"[BLOCKED-delegate] iesim_messageDeleted msg=%@ conv=%@ reason=%@", msgID, convID, reason);
    // 吞掉，不调原始实现
}

static void YPD_Hook_BatchDeleted(id self, SEL _cmd, NSArray *msgIDs, NSDictionary *map)
{
    YPD_LOG(@"[BLOCKED-delegate] batch deleted %lu msgs", (unsigned long)msgIDs.count);
    // 吞掉
}

// ──────────────────────────────────────────────
//  运行时 hook 入口
// ──────────────────────────────────────────────

static void YPD_HookFlowIMDelete(void)
{
    // 找到实现了 FlowIMChatService 协议的类
    Protocol *chatServiceProto = objc_getProtocol("FlowIMChatService");
    if (!chatServiceProto) {
        // Swift 协议可能用 mangled name
        chatServiceProto = NSProtocolFromString(@"_TtP7FlowIMX17FlowIMChatService_");
    }
    if (!chatServiceProto) {
        // fallback: 直接遍历所有类找实现了 deleteMessagesWithMsgIDs:callBack: 的
        YPD_LOG(@"Protocol lookup failed, falling back to method scan...");
        SEL delSel = NSSelectorFromString(@"deleteMessagesWithMsgIDs:callBack:");
        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        for (unsigned int i = 0; i < count; i++) {
            Method m = class_getInstanceMethod(classes[i], delSel);
            if (m) {
                const char *name = class_getName(classes[i]);
                YPD_LOG(@"Found deleteMessagesWithMsgIDs:callBack: on %s", name);
                YPD_Orig_DeleteMessages = method_setImplementation(m, (IMP)YPD_Hook_DeleteMessages);
                YPD_LOG(@"  -> hooked");
            }
        }
        free(classes);
    } else {
        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        unsigned int hooked = 0;
        SEL delSel = NSSelectorFromString(@"deleteMessagesWithMsgIDs:callBack:");
        for (unsigned int i = 0; i < count; i++) {
            if (class_conformsToProtocol(classes[i], chatServiceProto)) {
                const char *name = class_getName(classes[i]);
                YPD_LOG(@"Found FlowIMChatService implementor: %s", name);
                Method m = class_getInstanceMethod(classes[i], delSel);
                if (m) {
                    YPD_Orig_DeleteMessages = method_setImplementation(m, (IMP)YPD_Hook_DeleteMessages);
                    hooked++;
                    YPD_LOG(@"  -> hooked deleteMessagesWithMsgIDs:callBack:");
                }
            }
        }
        free(classes);
        YPD_LOG(@"Hooked %u FlowIMChatService classes", hooked);
    }

    // Hook FlowIMConversationService
    Protocol *convServiceProto = objc_getProtocol("FlowIMConversationService");
    if (!convServiceProto) {
        convServiceProto = NSProtocolFromString(@"_TtP7FlowIMX25FlowIMConversationService_");
    }
    if (convServiceProto) {
        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        SEL convSel = NSSelectorFromString(@"deleteConversationWith:success:fail:");
        for (unsigned int i = 0; i < count; i++) {
            if (class_conformsToProtocol(classes[i], convServiceProto)) {
                Method m = class_getInstanceMethod(classes[i], convSel);
                if (m) {
                    YPD_Orig_DeleteConversation = method_setImplementation(m, (IMP)YPD_Hook_DeleteConversation);
                    YPD_LOG(@"Hooked FlowIMConversationService on %s", class_getName(classes[i]));
                }
            }
        }
        free(classes);
    }
}

static void YPD_HookDelegateCallbacks(void)
{
    Protocol *delegateProto = objc_getProtocol("IESIMChatDataManagerDelegate");
    if (!delegateProto) {
        YPD_LOG(@"IESIMChatDataManagerDelegate protocol not found");
        return;
    }

    SEL selSingle = NSSelectorFromString(@"iesim_messageDeleted:inConversation:reason:");
    SEL selBatch = NSSelectorFromString(@"iesim_onConversationDataSourceMessagesDeleted:belongingConversationMap:");

    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    unsigned int hooked = 0;
    for (unsigned int i = 0; i < count; i++) {
        Class c = classes[i];
        if (class_conformsToProtocol(c, delegateProto)) {
            Method m1 = class_getInstanceMethod(c, selSingle);
            if (m1) {
                const char *type = method_getTypeEncoding(m1);
                YPD_Orig_MsgDeleted = class_replaceMethod(c, selSingle, (IMP)YPD_Hook_MsgDeleted, type);
                hooked++;
            }
            Method m2 = class_getInstanceMethod(c, selBatch);
            if (m2) {
                const char *type = method_getTypeEncoding(m2);
                YPD_Orig_BatchDeleted = class_replaceMethod(c, selBatch, (IMP)YPD_Hook_BatchDeleted, type);
            }
        }
    }
    free(classes);
    YPD_LOG(@"Hooked %u delegate classes for delete callbacks", hooked);
}

// ──────────────────────────────────────────────
//  %ctor
// ──────────────────────────────────────────────

%ctor {
    YPD_LOG_BUFFER = [NSMutableArray array];
    YPD_LOG(@"YukiPreventDelete v0.2 loading...");

    // FlowIMX 作为动态库可能在 AwemeCore 之后加载，给足够时间
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        YPD_LOG(@"Starting hook installation...");
        YPD_HookFlowIMDelete();
        YPD_HookDelegateCallbacks();
        YPD_LOG(@"Hook installation complete.");
    });

    // 二次重试：7s 后再扫一次（部分类可能延迟注册）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(7.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!YPD_Orig_DeleteMessages) {
            YPD_LOG(@"Retry: no P0 hook found at 4s, scanning again...");
            YPD_HookFlowIMDelete();
        }
    });
}
