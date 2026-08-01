#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ────────────── DEBUG ──────────────
#define YPD_LOG(fmt, ...) \
    do { \
        NSString *_log = [NSString stringWithFormat:@"[YPD] " fmt, ##__VA_ARGS__]; \
        printf("%s\n", _log.UTF8String); \
        [YPD_LOG_BUFFER addObject:_log]; \
        if (YPD_LOG_BUFFER.count > 200) [YPD_LOG_BUFFER removeObjectAtIndex:0]; \
    } while(0)

static NSMutableArray<NSString *> *YPD_LOG_BUFFER;
static BOOL YPD_ENABLE_VERBOSE_LOG = YES;

// ────────────── PREFERENCES ──────────────
static NSString *const kYPDEnabledKey       = @"YPD_Enabled";
static NSString *const kYPDPreventDeleteKey = @"YPD_PreventRemoteDelete";
static NSString *const kYPDFallbackKey      = @"YPD_AlsoBlockUIDelete"; // 第二道防线

static inline BOOL YPD_Enabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kYPDEnabledKey] ?: YES; // 默认开启
}
static inline BOOL YPD_PreventRemoteDelete(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kYPDPreventDeleteKey] ?: YES;
}
static inline BOOL YPD_AlsoBlockUIDelete(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kYPDFallbackKey] ?: NO;
}

// ────────────── REMOTE DELETE FLAG ──────────────
// 当本端主动调用 AWEIMMessageListActionDeleteInterface 删除时设置此标记，
// 回调中检测到标记则放行（本端操作），否则拦截（远端操作）
static BOOL YPD_IsLocalDeleteInProgress = NO;
static NSInteger YPD_LocalDeleteGuardCounter = 0;

// ───── Swizzle 函数声明 ─────
static void YPD_SwizzleInstanceMethod(Class cls, SEL original, IMP replacement);
static void YPD_RestoreMethod(Class cls, SEL original, IMP saved);

// 保存原始 IMP
static IMP YPD_Orig_MsgDeleted = NULL;
static IMP YPD_Orig_BatchMessagesDeleted = NULL;
static IMP YPD_Orig_ConvDataSourceMsgsDeleted = NULL;

// ──────────────────────────────────────────────
//  策略 A：数据层 — IESIMChatDataManagerDelegate
// ──────────────────────────────────────────────

// 单条消息删除：iesim_messageDeleted:inConversation:reason:
static void YPD_Hook_MsgDeleted(id self, SEL _cmd,
                                 NSString *msgID,
                                 NSString *convID,
                                 NSString *reason)
{
    if (!YPD_Enabled() || !YPD_PreventRemoteDelete()) goto passthrough;
    if (YPD_IsLocalDeleteInProgress) {
        YPD_LOG(@"[LOCAL OK] 本端删除 msg=%@ conv=%@ reason=%@", msgID, convID, reason);
        goto passthrough;
    }
    YPD_LOG(@"[BLOCKED] 远端删除 msg=%@ conv=%@ reason=%@", msgID, convID, reason);
    return;
passthrough:
    if (YPD_Orig_MsgDeleted) {
        ((void(*)(id, SEL, NSString*, NSString*, NSString*))YPD_Orig_MsgDeleted)(self, _cmd, msgID, convID, reason);
    }
}

// 批量消息删除：iesim_onConversationDataSourceMessagesDeleted:belongingConversationMap:
static void YPD_Hook_BatchMessagesDeleted(id self, SEL _cmd,
                                           NSArray *msgIdentifiers,
                                           NSDictionary *belongingConvMap)
{
    if (!YPD_Enabled() || !YPD_PreventRemoteDelete()) goto passthrough;
    if (YPD_IsLocalDeleteInProgress) {
        YPD_LOG(@"[LOCAL OK] 本端批量删除 msgs=%@ map=%@", msgIdentifiers, belongingConvMap);
        goto passthrough;
    }
    YPD_LOG(@"[BLOCKED] 远端批量删除 msgs=%@ map=%@", msgIdentifiers, belongingConvMap);
    return;
passthrough:
    if (YPD_Orig_BatchMessagesDeleted) {
        ((void(*)(id, SEL, NSArray*, NSDictionary*))YPD_Orig_BatchMessagesDeleted)(self, _cmd, msgIdentifiers, belongingConvMap);
    }
}

// ──────────────────────────────────────────────
//  策略 B：UI 层 — AWEIMMessageListViewController
// ──────────────────────────────────────────────

// 防撤回的同类——同时在 AWEIMMessageListViewController 内拦截
// handleRecallMessageNotification: 的兄弟方法可能是 handleDeleteMessageNotification:
// 如果没有，则拦截其底层数据源刷新方法 deleteRowsAtIndexPaths:

static IMP YPD_Orig_DeleteRowsAtIndexPaths = NULL;

static void YPD_Hook_DeleteRowsAtIndexPaths(id self, SEL _cmd,
                                             NSArray *indexPaths,
                                             UITableViewRowAnimation animation)
{
    if (!YPD_Enabled() || !YPD_AlsoBlockUIDelete()) goto passthrough;
    if (YPD_IsLocalDeleteInProgress) goto passthrough;
    YPD_LOG(@"[UI BLOCKED] 拦截 UI 层 deleteRows count=%lu", (unsigned long)indexPaths.count);
    return;
passthrough:
    if (YPD_Orig_DeleteRowsAtIndexPaths) {
        ((void(*)(id, SEL, NSArray*, UITableViewRowAnimation))YPD_Orig_DeleteRowsAtIndexPaths)(self, _cmd, indexPaths, animation);
    }
}

// ──────────────────────────────────────────────
//  策略 C：拦截本端删除标记
// ──────────────────────────────────────────────

// 本端删除走 AWEIMMessageListActionDeleteInterface
// 实现该协议的类调用方法前设置 YPD_IsLocalDeleteInProgress = YES
// 完成后恢复

static void YPD_SetLocalDeleteFlag(void) {
    YPD_IsLocalDeleteInProgress = YES;
    YPD_LocalDeleteGuardCounter++;
    // 安全网：500ms 后自动清除，防止忘记恢复导致所有删除放行
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
//  Swizzle 工具函数
// ──────────────────────────────────────────────

static void YPD_SwizzleInstanceMethod(Class cls, SEL original, IMP replacement)
{
    if (!cls || !original || !replacement) return;
    Method m = class_getInstanceMethod(cls, original);
    if (!m) return;
    const char *type = method_getTypeEncoding(m);
    IMP old = class_replaceMethod(cls, original, replacement, type ?: "@@:");
    // 如果 replace 成功返回的 old 就是原始 IMP
    // 但如果类本身没实现该方法（在父类），replace 返回 NULL
    if (!old) {
        // 方法在父类，用 exchange 方式
        old = method_getImplementation(m);
        method_setImplementation(m, replacement);
    }
    // old 此时就是真正的原始 IMP（不管是当前类还是父类）
    // 存储到对应的静态变量中
    if (sel_isEqual(original, @selector(iesim_messageDeleted:inConversation:reason:))) {
        YPD_Orig_MsgDeleted = old;
    } else if (sel_isEqual(original, @selector(iesim_onConversationDataSourceMessagesDeleted:belongingConversationMap:))) {
        YPD_Orig_BatchMessagesDeleted = old;
    }
}

// ──────────────────────────────────────────────
//  运行时查找 delegate 实现类
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
    for (unsigned int i = 0; i < count; i++) {
        Class c = classes[i];
        if (class_conformsToProtocol(c, delegateProto)) {
            const char *name = class_getName(c);
            YPD_LOG(@"FOUND delegate class: %s", name);

            // Hook 单条删除
            SEL selSingle = @selector(iesim_messageDeleted:inConversation:reason:);
            Method mSingle = class_getInstanceMethod(c, selSingle);
            if (mSingle) {
                const char *typeSingle = method_getTypeEncoding(mSingle);
                IMP oldSingle = class_replaceMethod(c, selSingle, (IMP)YPD_Hook_MsgDeleted, typeSingle);
                YPD_Orig_MsgDeleted = oldSingle ?: method_getImplementation(mSingle);
                YPD_LOG(@"  -> hooked iesim_messageDeleted:inConversation:reason:");
            }

            // Hook 批量删除
            SEL selBatch = @selector(iesim_onConversationDataSourceMessagesDeleted:belongingConversationMap:);
            Method mBatch = class_getInstanceMethod(c, selBatch);
            if (mBatch) {
                const char *typeBatch = method_getTypeEncoding(mBatch);
                IMP oldBatch = class_replaceMethod(c, selBatch, (IMP)YPD_Hook_BatchMessagesDeleted, typeBatch);
                YPD_Orig_BatchMessagesDeleted = oldBatch ?: method_getImplementation(mBatch);
                YPD_LOG(@"  -> hooked iesim_onConversationDataSourceMessagesDeleted:belongingConversationMap:");
            }
        }
    }
    free(classes);

    if (!YPD_Orig_MsgDeleted) {
        YPD_LOG(@"WARNING: No delegate class hooked. Falling back to UI layer.");
    }
}

// ──────────────────────────────────────────────
//  UI 层兜底 hook
// ──────────────────────────────────────────────

static void YPD_SetupUIFallback(void)
{
    // Hook AWEIMMessageListViewController 删除相关方法
    Class vcClass = objc_getClass("AWEIMMessageListViewController");
    if (!vcClass) {
        YPD_LOG(@"AWEIMMessageListViewController class not found");
        return;
    }
    YPD_LOG(@"AWEIMMessageListViewController found, setting up UI hooks");

    // 尝试 hook deleteRowsAtIndexPaths（UITableView 方法）
    // 注意：这 hook 的是 tableView 对象，不是 VC
    // 需要在 tableView 创建后动态 hook

    // 方案：hook VC 的 viewDidLoad 来捕获 tableView
    SEL vdlSel = @selector(viewDidLoad);
    Method vdlMethod = class_getInstanceMethod(vcClass, vdlSel);
    if (!vdlMethod) return;
    IMP vdlOrig = method_getImplementation(vdlMethod);

    IMP vdlNew = imp_implementationWithBlock(^(id self) {
        ((void(*)(id, SEL))vdlOrig)(self, vdlSel);
        // 延迟 hook tableView
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            // 遍历 subviews 找 UITableView
            UIView *view = ((UIViewController *)self).view;
            for (UIView *sub in view.subviews) {
                if ([sub isKindOfClass:[UITableView class]]) {
                    if (!YPD_Orig_DeleteRowsAtIndexPaths) {
                        YPD_Orig_DeleteRowsAtIndexPaths =
                            class_replaceMethod([sub class],
                                @selector(deleteRowsAtIndexPaths:withRowAnimation:),
                                (IMP)YPD_Hook_DeleteRowsAtIndexPaths,
                                "v@:@@Q");
                        YPD_LOG(@"Hooked UITableView deleteRowsAtIndexPaths on %s",
                                class_getName([sub class]));
                    }
                }
            }
        });
    });
    // 不替换 viewDidLoad，改为在 %ctor 中另做
    (void)vdlNew;
}

// ──────────────────────────────────────────────
//  Constructor
// ──────────────────────────────────────────────

__attribute__((constructor))
static void YPD_Init(void)
{
    YPD_LOG_BUFFER = [NSMutableArray array];

    // 延迟执行，等 AwemeCore 加载完毕
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        YPD_LOG(@"YukiPreventDelete v0.1 loaded");
        YPD_FindAndHookDelegateClass();
    });
}

// ──────────────────────────────────────────────
//  NSUserDefaults 设置界面入口
// ──────────────────────────────────────────────

// 通过 TrollFools 注入的用户可通过任意方式写入：
//  defaults write com.ss.iphone.ugc.Aweme YPD_Enabled -bool YES
//  defaults write com.ss.iphone.ugc.Aweme YPD_PreventRemoteDelete -bool YES

// ──────────────────────────────────────────────
//  %ctor for substrate
// ──────────────────────────────────────────────

%ctor {
    // substrate 路径的初始化
    YPD_LOG_BUFFER = [NSMutableArray array];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        YPD_LOG(@"YukiPreventDelete v0.1 (substrate) loaded");
        YPD_FindAndHookDelegateClass();
    });
}
