// 不操作桌面 UI 的下载验证宿主：通过 Sparkle 公共 user driver 回调测试取消、签名失败及重定向。
// 测试确认仅允许下载；到达可安装阶段即跳过，原应用包必须保持原构建号。

#import <AppKit/AppKit.h>
#import <Sparkle/Sparkle.h>

@interface DownloadProbe : NSObject <SPUUserDriver, SPUUpdaterDelegate>
@property(nonatomic, strong) SPUUpdater *updater;
@property(nonatomic, copy) NSString *mode;
@property(nonatomic, copy) NSString *outcome;
@property(nonatomic, copy) NSString *detail;
@property(nonatomic, copy) void (^cancelDownload)(void);
@property(nonatomic) BOOL cancelled;
- (void)finish;
@end

@implementation DownloadProbe
- (void)showUpdatePermissionRequest:(SPUUpdatePermissionRequest *)request reply:(void (^)(SUUpdatePermissionResponse *))reply {
    reply([[SUUpdatePermissionResponse alloc] initWithAutomaticUpdateChecks:NO sendSystemProfile:NO]);
}
- (void)showUserInitiatedUpdateCheckWithCancellation:(void (^)(void))cancellation {}
- (void)showUpdateFoundWithAppcastItem:(SUAppcastItem *)item state:(SPUUserUpdateState *)state reply:(void (^)(SPUUserUpdateChoice))reply {
    reply(SPUUserUpdateChoiceInstall);
}
- (void)showUpdateReleaseNotesWithDownloadData:(SPUDownloadData *)data {}
- (void)showUpdateReleaseNotesFailedToDownloadWithError:(NSError *)error {}
- (void)showUpdateNotFoundWithError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement {
    self.outcome = @"no-update";
    acknowledgement();
}
- (void)showUpdaterError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement {
    self.outcome = @"error";
    self.detail = error.localizedDescription;
    acknowledgement();
}
- (void)showDownloadInitiatedWithCancellation:(void (^)(void))cancellation {
    self.cancelDownload = cancellation;
}
- (void)showDownloadDidReceiveExpectedContentLength:(uint64_t)length {}
- (void)showDownloadDidReceiveDataOfLength:(uint64_t)length {
    if ([self.mode isEqualToString:@"slow"] && !self.cancelled && self.cancelDownload) {
        self.cancelled = YES;
        self.outcome = @"cancelled";
        self.cancelDownload();
    }
}
- (void)showDownloadDidStartExtractingUpdate {}
- (void)showExtractionReceivedProgress:(double)progress {}
- (void)showReadyToInstallAndRelaunch:(void (^)(SPUUserUpdateChoice))reply {
    self.outcome = @"validated";
    reply(SPUUserUpdateChoiceSkip);
}
- (void)showInstallingUpdateWithApplicationTerminated:(BOOL)terminated retryTerminatingApplication:(void (^)(void))retry {
    self.outcome = @"unexpected-install";
    [self finish];
}
- (void)showUpdateInstalledAndRelaunched:(BOOL)relaunched acknowledgement:(void (^)(void))acknowledgement {
    self.outcome = @"unexpected-install";
    acknowledgement();
}
- (void)dismissUpdateInstallation {}
- (void)updater:(SPUUpdater *)updater didFinishUpdateCycleForUpdateCheck:(SPUUpdateCheck)check error:(NSError *)error {
    [self finish];
}
- (void)finish {
    NSString *expected = [@{@"valid": @"validated", @"redirect": @"validated", @"slow": @"cancelled",
                           @"no-update": @"no-update", @"corrupt": @"error", @"wrong-key": @"error",
                           @"tampered-feed": @"error"} objectForKey:self.mode];
    NSString *build = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"];
    BOOL passed = [self.outcome isEqualToString:expected] && [build isEqualToString:@"30001"];
    NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"case": self.mode, @"outcome": self.outcome ?: @"timeout",
                           @"build": build ?: @"", @"passed": @(passed), @"detail": self.detail ?: @""}
                                                        options:0 error:nil];
    puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    exit(passed ? 0 : 1);
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"SUEnableAutomaticChecks"];
        DownloadProbe *probe = [[DownloadProbe alloc] init];
        probe.mode = argc > 1 ? @(argv[1]) : @"valid";
        probe.updater = [[SPUUpdater alloc] initWithHostBundle:[NSBundle mainBundle] applicationBundle:[NSBundle mainBundle]
                                                  userDriver:probe delegate:probe];
        NSError *error = nil;
        if (![probe.updater startUpdater:&error]) {
            probe.outcome = @"startup-error";
            probe.detail = error.localizedDescription;
            [probe finish];
        }
        [probe.updater checkForUpdates];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [probe finish];
        });
        [NSApp run];
    }
}
