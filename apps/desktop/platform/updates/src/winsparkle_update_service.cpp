#include "mokaid/updates/update_service.hpp"
#include <QCoreApplication>
#include <QMetaObject>
#include <QThread>
#include <winsparkle.h>
#include <stdexcept>

namespace mokaid::updates {
namespace {
// WinSparkle's C API is process-wide and has no callback context. This pointer
// is confined to its adapter; cleanup joins SDK threads before it is cleared.
class WinSparkleUpdateService;
std::atomic<WinSparkleUpdateService*> activeService{nullptr};
class WinSparkleUpdateService final : public UpdateService {
public:
    ~WinSparkleUpdateService() override {
        if (started_) {
            win_sparkle_cleanup();
            activeService.store(nullptr, std::memory_order_release);
        }
    }
    bool available() const noexcept override { return true; }
    void startup() override {
        Q_ASSERT(QThread::currentThread() == thread());
        if (started_) return;
        WinSparkleUpdateService* empty = nullptr;
        if (!activeService.compare_exchange_strong(empty, this)) {
            emit error(tr("Only one update service may run in this application."));
            return;
        }
        const auto version = QCoreApplication::applicationVersion().toStdWString();
        const auto product = channel() == QStringLiteral("beta") ? L"Mokaid Beta" : L"Mokaid";
        win_sparkle_set_app_details(L"Yapio Ltd", product, version.c_str());
        const auto buildVersion = QCoreApplication::applicationVersion().replace(QStringLiteral("-beta."), QStringLiteral("b")).toStdWString();
        win_sparkle_set_app_build_version(buildVersion.c_str());
        win_sparkle_set_appcast_url(MOKAID_UPDATE_FEED_URL);
        if (win_sparkle_set_eddsa_public_key(MOKAID_UPDATE_PUBLIC_KEY) != 1) {
            activeService.store(nullptr, std::memory_order_release);
            emit error(tr("The application's update signing key is invalid."));
            return;
        }
        win_sparkle_set_update_check_interval(86400);
        win_sparkle_set_automatic_check_for_updates(1);
        win_sparkle_set_error_callback([] {
            if (auto* self = activeService.load(std::memory_order_acquire))
                QMetaObject::invokeMethod(self, [self] {
                    emit self->error(tr("The update could not be verified or downloaded."));
                }, Qt::QueuedConnection);
        });
        win_sparkle_set_can_shutdown_callback([]() -> int {
            auto* self = activeService.load(std::memory_order_acquire);
            if (!self) return 0;
            if (self->installationAllowed()) return 1;
            QMetaObject::invokeMethod(self, [self] { emit self->saveRequired(); }, Qt::QueuedConnection);
            return 0;
        });
        win_sparkle_set_shutdown_request_callback([] {
            QMetaObject::invokeMethod(QCoreApplication::instance(), &QCoreApplication::quit,
                                      Qt::QueuedConnection);
        });
        started_ = true;
        win_sparkle_init();
    }
    void checkForUpdates() override {
        startup();
        if (started_) win_sparkle_check_update_with_ui();
    }
private:
    bool started_{false};
};
}
std::unique_ptr<UpdateService> createUpdateService() {
    return std::make_unique<WinSparkleUpdateService>();
}
}
