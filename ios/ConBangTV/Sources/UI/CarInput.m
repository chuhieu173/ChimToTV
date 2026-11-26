#import "WebKitSPI.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// Ô nhập chữ trên màn xe (CarPlay, UI/CarScreen.swift): bàn phím hệ thống hiện trên màn xe bị lỗi (CarTube cũng gặp), nên
// thay bằng một khung rỗng — app tự vẽ bàn phím riêng (CarKeyboard) và gõ vào ô qua UIKeyInput. Chỉ đổi khi ô nằm trong cảnh
// CarPlay; ô trên điện thoại / iPad / Mac giữ bàn phím hệ thống.

static BOOL CBTCarKeyboardOn = YES;

void CBTSetCarKeyboard(BOOL on) { CBTCarKeyboardOn = on; }
BOOL CBTCarKeyboardEnabled(void) { return CBTCarKeyboardOn; }

static BOOL CBTOnCarScreen(UIView *v) {
    if (!CBTCarKeyboardOn) return NO;
    UIWindowScene *scene = v.window.windowScene;
    return [scene.session.role isEqualToString:@"UIWindowSceneSessionRoleCarPlay"];
}

static UIView *CBTEmptyInputView(void) {
    static UIView *view;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        view = [[UIView alloc] initWithFrame:CGRectZero];
        view.autoresizingMask = UIViewAutoresizingNone;
    });
    return view;
}

/// Thay hàm đọc `inputView` của lớp (thêm vào chính lớp đó nếu nó chỉ thừa kế từ UIResponder — không đụng lớp cha).
static void CBTHookInputView(Class cls) {
    SEL sel = @selector(inputView);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP original = method_getImplementation(m);
    IMP replacement = imp_implementationWithBlock(^UIView *(UIView *me) {
        if (CBTOnCarScreen(me)) return CBTEmptyInputView();
        return ((UIView * (*)(id, SEL))original)(me, sel);
    });
    if (!class_addMethod(cls, sel, replacement, method_getTypeEncoding(m))) {
        method_setImplementation(m, replacement);
    }
}

void CBTInstallCarInput(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CBTHookInputView([UITextField class]);
        CBTHookInputView([UITextView class]);
    });
}
