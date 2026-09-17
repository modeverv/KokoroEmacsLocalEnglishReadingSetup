#import <Cocoa/Cocoa.h>
#include <ifaddrs.h>
#include <arpa/inet.h>
#include <net/if.h>

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property NSWindow *window;
@property NSTextField *status;
@property NSTextField *detail;
@property NSButton *startButton;
@property NSButton *stopButton;
@property BOOL busy;
@property NSString *pendingAction;
@property NSString *root;
@end

@implementation AppDelegate
- (NSString *)lanAddress {
    struct ifaddrs *addresses = NULL;
    NSString *address = @"このMacのLANアドレス";
    if (getifaddrs(&addresses) == 0) {
        for (struct ifaddrs *item = addresses; item; item = item->ifa_next) {
            if (!item->ifa_addr || item->ifa_addr->sa_family != AF_INET ||
                !(item->ifa_flags & IFF_UP) || (item->ifa_flags & IFF_LOOPBACK) ||
                strncmp(item->ifa_name, "en", 2) != 0) continue;
            char buffer[INET_ADDRSTRLEN];
            if (inet_ntop(AF_INET, &((struct sockaddr_in *)item->ifa_addr)->sin_addr,
                          buffer, sizeof(buffer))) {
                address = [NSString stringWithUTF8String:buffer];
                break;
            }
        }
        freeifaddrs(addresses);
    }
    return address;
}
- (NSTextField *)label:(NSString *)text size:(CGFloat)size {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:size];
    label.lineBreakMode = NSLineBreakByWordWrapping;
    label.maximumNumberOfLines = 0;
    return label;
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.root = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"ReaderSpeechRoot"];
    NSMenu *menu = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new];
    [menu addItem:appItem];
    NSMenu *appMenu = [NSMenu new];
    [appMenu addItemWithTitle:@"Reader Speech Server を終了" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    NSApp.mainMenu = menu;
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 570, 405)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Reader Speech Server";
    self.window.releasedWhenClosed = NO;
    NSStackView *stack = [NSStackView new];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 18;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    NSImage *icon = [[NSImage alloc] initWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"SpeechServer" ofType:@"icns"]];
    if (icon) NSApp.applicationIconImage = icon;
    NSImageView *image = [NSImageView imageViewWithImage:icon ?: [NSImage imageNamed:NSImageNameApplicationIcon]];
    [image.widthAnchor constraintEqualToConstant:64].active = YES;
    [image.heightAnchor constraintEqualToConstant:64].active = YES;
    NSStackView *heading = [NSStackView stackViewWithViews:@[image, [self label:@"読み上げサーバー" size:26]]];
    heading.spacing = 16;
    [stack addArrangedSubview:heading];
    [stack addArrangedSubview:[self label:@"英語・日本語の音声をEmacsや外部アプリへ配信します。" size:13]];
    self.status = [self label:@"状態を確認中…" size:18];
    [stack addArrangedSubview:self.status];
    NSStackView *buttons = [NSStackView new];
    buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    buttons.spacing = 16;
    self.startButton = [NSButton buttonWithTitle:@"サーバースタート" target:self action:@selector(start:)];
    self.stopButton = [NSButton buttonWithTitle:@"停止" target:self action:@selector(stop:)];
    [buttons addArrangedSubview:self.startButton];
    [buttons addArrangedSubview:self.stopButton];
    [stack addArrangedSubview:buttons];
    self.detail = [self label:@"待受: 0.0.0.0:8765\nEmacs接続先: http://127.0.0.1:8765" size:13];
    [stack addArrangedSubview:self.detail];
    [stack addArrangedSubview:[self label:@"英語: Kokoro / macOS　日本語: Kokoro / Irodori / macOS" size:12]];
    [stack addArrangedSubview:[self label:@"アプリを閉じても配信は継続します。停止には「停止」を使います。\nEmacsで読み上げると、停止中のサーバーは自動起動します。" size:12]];
    [self.window.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.window.contentView.leadingAnchor constant:28],
        [stack.trailingAnchor constraintEqualToAnchor:self.window.contentView.trailingAnchor constant:-28],
        [stack.topAnchor constraintEqualToAnchor:self.window.contentView.topAnchor constant:24]
    ]];
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [self runAction:@"status"];
    [NSTimer scheduledTimerWithTimeInterval:2 target:self selector:@selector(refresh:) userInfo:nil repeats:YES];
}
- (void)runAction:(NSString *)action {
    if (self.busy) {
        if (![action isEqualToString:@"status"]) self.pendingAction = action;
        return;
    }
    self.busy = YES;
    if (![action isEqualToString:@"status"]) {
        self.startButton.enabled = NO;
        self.stopButton.enabled = NO;
        self.status.stringValue = [action isEqualToString:@"start"] ? @"起動中…" : @"停止中…";
    }
    NSString *root = self.root;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSTask *task = [NSTask new];
        task.executableURL = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@".venv/bin/python"]];
        task.currentDirectoryURL = [NSURL fileURLWithPath:root];
        task.arguments = @[@"-m", @"speech_http.service", action];
        NSPipe *pipe = [NSPipe pipe];
        task.standardOutput = pipe;
        task.standardError = pipe;
        NSError *error = nil;
        NSData *data = nil;
        BOOL launched = [task launchAndReturnError:&error];
        if (launched) {
            data = [pipe.fileHandleForReading readDataToEndOfFile];
            [task waitUntilExit];
        }
        NSDictionary *state = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        NSString *failure = error.localizedDescription ?: [[NSString alloc] initWithData:data ?: [NSData data] encoding:NSUTF8StringEncoding];
        BOOL success = launched && task.terminationStatus == 0 && state != nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            if (!success) {
                self.status.stringValue = @"操作に失敗しました";
                self.detail.stringValue = failure ?: @"起動設定を確認してください。";
                self.startButton.enabled = YES;
                self.stopButton.enabled = YES;
            } else {
                BOOL running = [state[@"ok"] boolValue];
                self.status.stringValue = running ? @"● サーバー稼働中" : @"○ サーバー停止中";
                self.startButton.enabled = !running;
                self.stopButton.enabled = running;
                self.detail.stringValue = [NSString stringWithFormat:@"待受: %@:8765\nこのMac: http://127.0.0.1:8765\nLAN接続: http://%@:8765", state[@"host"] ?: @"0.0.0.0", [self lanAddress]];
            }
            if (self.pendingAction) {
                NSString *pending = self.pendingAction;
                self.pendingAction = nil;
                [self runAction:pending];
            }
        });
    });
}
- (void)refresh:(NSTimer *)timer { [self runAction:@"status"]; }
- (void)start:(id)sender { [self runAction:@"start"]; }
- (void)stop:(id)sender { [self runAction:@"stop"]; }
- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)visible {
    [self.window makeKeyAndOrderFront:nil];
    return YES;
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
