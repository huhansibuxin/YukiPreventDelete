#import <Foundation/Foundation.h>
#import <substrate.h>

#pragma mark - AWEIMNewMessageDataController delete hooks

static void (*orig_deleteMessage_sendToServer_completion)(id, SEL, id, BOOL, id);
static void (*orig_deleteMessage_sendToServer)(id, SEL, id, BOOL);
static void (*orig_deleteMessageInMemory)(id, SEL, id);
static void (*orig_deleteMessageInMemory_shouldReload)(id, SEL, id, BOOL);
static void (*orig_batchDeleteMessageIds)(id, SEL, id);

static void hook_deleteMessage_sendToServer_completion(id self, SEL _cmd, id message, BOOL sendToServer, id completion) {
    NSLog(@"[YPD] BLOCKED deleteMessage:sendToServer:completion: message=%@ sendToServer=%d", message, sendToServer);
}

static void hook_deleteMessage_sendToServer(id self, SEL _cmd, id message, BOOL sendToServer) {
    NSLog(@"[YPD] BLOCKED deleteMessage:sendToServer: message=%@ sendToServer=%d", message, sendToServer);
}

static void hook_deleteMessageInMemory(id self, SEL _cmd, id message) {
    NSLog(@"[YPD] BLOCKED deleteMessageInMemory: message=%@", message);
}

static void hook_deleteMessageInMemory_shouldReload(id self, SEL _cmd, id message, BOOL shouldReload) {
    NSLog(@"[YPD] BLOCKED deleteMessageInMemory:shouldReload: message=%@ shouldReload=%d", message, shouldReload);
}

static void hook_batchDeleteMessageIds(id self, SEL _cmd, id messageArray) {
    NSLog(@"[YPD] BLOCKED batchDeleteMessageIds: count=%lu", (unsigned long)[messageArray count]);
}

%ctor {
    @autoreleasepool {
        Class cls = NSClassFromString(@"AWEIMNewMessageDataController");
        if (!cls) {
            NSLog(@"[YPD] ERROR: AWEIMNewMessageDataController class not found");
            return;
        }
        NSLog(@"[YPD] Found AWEIMNewMessageDataController, installing hooks...");

        MSHookMessageEx(cls,
            NSSelectorFromString(@"deleteMessage:sendToServer:completion:"),
            (IMP)&hook_deleteMessage_sendToServer_completion,
            (IMP*)&orig_deleteMessage_sendToServer_completion);

        MSHookMessageEx(cls,
            NSSelectorFromString(@"deleteMessage:sendToServer:"),
            (IMP)&hook_deleteMessage_sendToServer,
            (IMP*)&orig_deleteMessage_sendToServer);

        MSHookMessageEx(cls,
            NSSelectorFromString(@"deleteMessageInMemory:"),
            (IMP)&hook_deleteMessageInMemory,
            (IMP*)&orig_deleteMessageInMemory);

        MSHookMessageEx(cls,
            NSSelectorFromString(@"deleteMessageInMemory:shouldReload:"),
            (IMP)&hook_deleteMessageInMemory_shouldReload,
            (IMP*)&orig_deleteMessageInMemory_shouldReload);

        MSHookMessageEx(cls,
            NSSelectorFromString(@"batchDeleteMessageIds:"),
            (IMP)&hook_batchDeleteMessageIds,
            (IMP*)&orig_batchDeleteMessageIds);

        NSLog(@"[YPD] All 5 delete hooks installed on AWEIMNewMessageDataController");
    }
}
