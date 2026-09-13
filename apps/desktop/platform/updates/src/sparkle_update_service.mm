#include "mokaid/updates/update_service.hpp"
#include <QThread>
#import <Sparkle/Sparkle.h>

@interface MokaidUpdaterDelegate : NSObject <SPUUpdaterDelegate>
@property(nonatomic, assign) mokaid::updates::UpdateService* service;
@property(nonatomic, copy) void (^resumeInstallation)(void);
@end

@implementation MokaidUpdaterDelegate
- (BOOL)updater:(SPUUpdater*)updater shouldPostponeRelaunchForUpdate:(SUAppcastItem*)item
    untilInvokingBlock:(void (^)(void))handler {
    (void)updater; (void)item;
    if (self.service && self.service->installationAllowed()) return NO;
    self.resumeInstallation = handler;
    if (self.service) emit self.service->saveRequired();
    return YES;
}
- (void)updater:(SPUUpdater*)updater didAbortWithError:(NSError*)error {
    (void)updater;
    if (self.service) emit self.service->error(QString::fromNSString(error.localizedDescription));
}
- (NSArray<NSString*>*)allowedSystemProfileKeysForUpdater:(SPUUpdater*)updater {
    (void)updater;
    return @[];
}
@end

namespace mokaid::updates {
namespace {
class SparkleUpdateService final : public UpdateService {
public:
    ~SparkleUpdateService() override {
        delegate_.service = nullptr;
        delegate_.resumeInstallation = nil;
        controller_ = nil;
        delegate_ = nil;
    }
    bool available() const noexcept override { return true; }
    void startup() override {
        Q_ASSERT(QThread::currentThread() == thread());
        if (controller_) return;
        delegate_ = [MokaidUpdaterDelegate new];
        delegate_.service = this;
        controller_ = [[SPUStandardUpdaterController alloc] initWithStartingUpdater:NO
            updaterDelegate:delegate_ userDriverDelegate:nil];
        NSError* failure = nil;
        if (![controller_.updater startUpdater:&failure]) {
            emit error(QString::fromNSString(failure.localizedDescription));
            controller_ = nil;
            return;
        }
    }
    void checkForUpdates() override {
        startup();
        if (controller_.updater.canCheckForUpdates) [controller_ checkForUpdates:nil];
    }
    void setInstallationAllowed(bool allowed) override {
        UpdateService::setInstallationAllowed(allowed);
        if (allowed && delegate_.resumeInstallation) {
            void (^resume)(void) = delegate_.resumeInstallation;
            delegate_.resumeInstallation = nil;
            resume();
        }
    }
private:
    SPUStandardUpdaterController* __strong controller_ = nil;
    MokaidUpdaterDelegate* __strong delegate_ = nil;
};
}
std::unique_ptr<UpdateService> createUpdateService() {
    return std::make_unique<SparkleUpdateService>();
}
}
