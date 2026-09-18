#import <Cocoa/Cocoa.h>
#include <ifaddrs.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <math.h>
#include <signal.h>

@interface PlaybackApp : NSObject <NSApplicationDelegate>
@property NSWindow *window;
@property NSTextField *status;
@property NSTextField *address;
@property NSTextField *port;
@property NSTextField *device;
@property NSTextField *prebuffer;
@property NSSecureTextField *token;
@property NSPopUpButton *host;
@property NSButton *startButton;
@property NSButton *stopButton;
@property NSTask *server;
@property NSString *logPath;
@property NSFileHandle *logHandle;
@property NSTimer *timer;
@property BOOL checking;
@property NSUInteger run;
@end

@implementation PlaybackApp
- (NSTextField *)label:(NSString *)text size:(CGFloat)size {
    NSTextField *field = [NSTextField labelWithString:text];
    field.font = [NSFont systemFontOfSize:size];
    field.lineBreakMode = NSLineBreakByWordWrapping;
    field.maximumNumberOfLines = 0;
    return field;
}
- (NSTextField *)field:(NSString *)value {
    NSTextField *field = [NSTextField textFieldWithString:value];
    [field.widthAnchor constraintEqualToConstant:310].active = YES;
    return field;
}
- (NSView *)row:(NSString *)name control:(NSView *)control {
    NSTextField *label = [self label:name size:13];
    [label.widthAnchor constraintEqualToConstant:140].active = YES;
    NSStackView *row = [NSStackView stackViewWithViews:@[label, control]];
    row.spacing = 10;
    row.alignment = NSLayoutAttributeCenterY;
    return row;
}
- (NSString *)lanAddress {
    struct ifaddrs *addresses = NULL;
    NSString *result = @"このMacのLANアドレス";
    if (getifaddrs(&addresses) == 0) {
        for (struct ifaddrs *item = addresses; item; item = item->ifa_next) {
            if (!item->ifa_addr || item->ifa_addr->sa_family != AF_INET ||
                !(item->ifa_flags & IFF_UP) || (item->ifa_flags & IFF_LOOPBACK) ||
                strncmp(item->ifa_name, "en", 2)) continue;
            char buffer[INET_ADDRSTRLEN];
            if (inet_ntop(AF_INET, &((struct sockaddr_in *)item->ifa_addr)->sin_addr,
                          buffer, sizeof(buffer))) {
                result = [NSString stringWithUTF8String:buffer];
                break;
            }
        }
        freeifaddrs(addresses);
    }
    return result;
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSMenu *menu = [NSMenu new];
    NSMenuItem *item = [NSMenuItem new];
    [menu addItem:item];
    NSMenu *appMenu = [NSMenu new];
    [appMenu addItemWithTitle:@"Reader Playback Server を終了" action:@selector(terminate:) keyEquivalent:@"q"];
    item.submenu = appMenu;
    NSApp.mainMenu = menu;
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 590, 510)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Reader Playback Server";
    self.window.releasedWhenClosed = NO;
    NSStackView *stack = [NSStackView new];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 14;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:[self label:@"手元で音声を再生" size:26]];
    [stack addArrangedSubview:[self label:@"生成サーバーから届く音声を再生し、Emacsへ完了を通知します。" size:13]];
    self.status = [self label:@"停止中" size:18];
    [stack addArrangedSubview:self.status];
    self.host = [NSPopUpButton new];
    [self.host addItemsWithTitles:@[@"このMacのみ（SSH接続用）", @"LANから接続（0.0.0.0）"]];
    [stack addArrangedSubview:[self row:@"接続範囲" control:self.host]];
    self.port = [self field:@"8768"];
    self.device = [self field:@""];
    self.device.placeholderString = @"空欄でシステム既定の出力";
    self.prebuffer = [self field:@"1.0"];
    self.token = [NSSecureTextField new];
    self.token.placeholderString = @"任意：Emacs側と同じトークン";
    [self.token.widthAnchor constraintEqualToConstant:310].active = YES;
    [stack addArrangedSubview:[self row:@"ポート" control:self.port]];
    [stack addArrangedSubview:[self row:@"音声出力デバイス" control:self.device]];
    [stack addArrangedSubview:[self row:@"先読み（秒）" control:self.prebuffer]];
    [stack addArrangedSubview:[self row:@"認証トークン" control:self.token]];
    self.startButton = [NSButton buttonWithTitle:@"サーバースタート" target:self action:@selector(start:)];
    self.stopButton = [NSButton buttonWithTitle:@"停止" target:self action:@selector(stop:)];
    self.stopButton.enabled = NO;
    NSButton *logs = [NSButton buttonWithTitle:@"ログを開く" target:self action:@selector(openLogs:)];
    NSStackView *buttons = [NSStackView stackViewWithViews:@[self.startButton, self.stopButton, logs]];
    buttons.spacing = 12;
    [stack addArrangedSubview:buttons];
    self.address = [self label:@"接続先: http://127.0.0.1:8768" size:13];
    self.address.selectable = YES;
    [stack addArrangedSubview:self.address];
    [stack addArrangedSubview:[self label:@"Intel / Apple Silicon・macOS Monterey以降\nアプリを終了すると再生サーバーも停止します。" size:12]];
    [self.window.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.window.contentView.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:self.window.contentView.trailingAnchor constant:-24],
        [stack.topAnchor constraintEqualToAnchor:self.window.contentView.topAnchor constant:24],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:self.window.contentView.bottomAnchor constant:-20]
    ]];
    NSString *directory = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/ReaderPlayback"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    self.logPath = [directory stringByAppendingPathComponent:@"server.log"];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(check:) userInfo:nil repeats:YES];
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}
- (void)inputsEnabled:(BOOL)enabled {
    for (NSControl *control in @[self.host, self.port, self.device, self.prebuffer, self.token]) control.enabled = enabled;
    self.startButton.enabled = enabled;
    self.stopButton.enabled = !enabled;
}
- (void)start:(id)sender {
    if (self.server.running) return;
    NSScanner *portScanner = [NSScanner scannerWithString:self.port.stringValue];
    int port = 0;
    NSScanner *bufferScanner = [NSScanner scannerWithString:self.prebuffer.stringValue];
    double buffer = -1;
    if (![portScanner scanInt:&port] || !portScanner.isAtEnd || port < 1 || port > 65535 ||
        ![bufferScanner scanDouble:&buffer] || !bufferScanner.isAtEnd || !isfinite(buffer) || buffer < 0 || buffer > 30) {
        self.status.stringValue = @"ポートは1〜65535、先読みは0〜30秒で指定してください";
        return;
    }
#if defined(__arm64__)
    NSString *arch = @"arm64";
#else
    NSString *arch = @"x86_64";
#endif
    NSString *resources = NSBundle.mainBundle.resourcePath;
    NSString *python = [resources stringByAppendingPathComponent:[NSString stringWithFormat:@"runtime-%@/bin/python3.12", arch]];
    NSString *host = self.host.indexOfSelectedItem == 0 ? @"127.0.0.1" : @"0.0.0.0";
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:python];
    NSMutableArray *arguments = [@[@"-I", @"-B", [resources stringByAppendingPathComponent:@"bootstrap.py"],
                                    @"--host", host, @"--port", [NSString stringWithFormat:@"%d", port],
                                    @"--prebuffer", self.prebuffer.stringValue] mutableCopy];
    if (self.device.stringValue.length) [arguments addObjectsFromArray:@[@"--device", self.device.stringValue]];
    task.arguments = arguments;
    task.currentDirectoryURL = [NSURL fileURLWithPath:NSHomeDirectory()];
    NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    environment[@"READER_PLAYBACK_TOKEN"] = self.token.stringValue;
    task.environment = environment;
    [[NSFileManager defaultManager] createFileAtPath:self.logPath contents:nil
        attributes:@{NSFilePosixPermissions: @0600}];
    self.logHandle = [NSFileHandle fileHandleForWritingAtPath:self.logPath];
    task.standardOutput = self.logHandle;
    task.standardError = self.logHandle;
    NSUInteger run = ++self.run;
    __weak PlaybackApp *weakSelf = self;
    task.terminationHandler = ^(NSTask *finished) {
        dispatch_async(dispatch_get_main_queue(), ^{
            PlaybackApp *app = weakSelf;
            if (!app || app.run != run) return;
            app.status.stringValue = finished.terminationStatus == 0 ? @"停止中" : @"起動・実行に失敗しました。ログを確認してください";
            [app inputsEnabled:YES];
            [app.logHandle closeFile];
            app.logHandle = nil;
            app.server = nil;
        });
    };
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        self.status.stringValue = [NSString stringWithFormat:@"起動できません: %@", error.localizedDescription];
        [self.logHandle closeFile];
        self.logHandle = nil;
        return;
    }
    self.server = task;
    self.status.stringValue = @"起動中…";
    self.address.stringValue = [NSString stringWithFormat:@"接続先: http://%@:%d", self.host.indexOfSelectedItem == 0 ? @"127.0.0.1" : self.lanAddress, port];
    [self inputsEnabled:NO];
}
- (void)stop:(id)sender {
    if (self.server.running) {
        self.status.stringValue = @"停止中…";
        self.stopButton.enabled = NO;
        [self.server terminate];
    }
}
- (void)check:(NSTimer *)timer {
    if (!self.server.running || self.checking) return;
    self.checking = YES;
    NSUInteger run = self.run;
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d/health", self.port.intValue]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 1;
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *result = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.checking = NO;
            if (self.run == run && self.server.running && self.stopButton.enabled &&
                [result[@"service"] isEqual:@"reader-playback"]) self.status.stringValue = @"稼働中";
        });
    }] resume];
}
- (void)openLogs:(id)sender {
    if ([[NSFileManager defaultManager] fileExistsAtPath:self.logPath])
        [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:self.logPath]];
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }
- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.timer invalidate];
    if (self.server.running) {
        [self.server terminate];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
        while (self.server.running && deadline.timeIntervalSinceNow > 0)
            [NSThread sleepForTimeInterval:0.05];
        if (self.server.running) kill(self.server.processIdentifier, SIGKILL);
    }
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        PlaybackApp *delegate = [PlaybackApp new];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app run];
    }
    return 0;
}
