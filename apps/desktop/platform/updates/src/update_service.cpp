#include "mokaid/updates/update_service.hpp"
#include <QThread>

namespace mokaid::updates {
QString UpdateService::channel() const { return QStringLiteral(MOKAID_RELEASE_CHANNEL); }
void UpdateService::setInstallationAllowed(bool allowed) {
    Q_ASSERT(QThread::currentThread() == thread());
    installationAllowed_.store(allowed, std::memory_order_release);
}

#if !MOKAID_ENABLE_UPDATES
namespace {
class UnavailableUpdater final : public UpdateService {
public:
    bool available() const noexcept override { return false; }
    void startup() override {}
    void checkForUpdates() override {
        emit error(tr("Automatic updates are unavailable in this development build."));
    }
};
}
std::unique_ptr<UpdateService> createUpdateService() {
    return std::make_unique<UnavailableUpdater>();
}
#endif
} // namespace mokaid::updates
