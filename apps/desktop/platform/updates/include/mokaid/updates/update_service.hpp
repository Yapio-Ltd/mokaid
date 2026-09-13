#pragma once

#include <QObject>
#include <QString>
#include <atomic>
#include <memory>

namespace mokaid::updates {

// Owned by the composition root; all methods except installationAllowed() run
// on Qt's GUI thread. A dirty document/upload must close the installation gate.
class UpdateService : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool available READ available CONSTANT)
    Q_PROPERTY(QString channel READ channel CONSTANT)
public:
    using QObject::QObject;
    ~UpdateService() override = default;
    [[nodiscard]] virtual bool available() const noexcept = 0;
    [[nodiscard]] QString channel() const;
    [[nodiscard]] bool installationAllowed() const noexcept {
        return installationAllowed_.load(std::memory_order_acquire);
    }
    Q_INVOKABLE virtual void startup() = 0;
    Q_INVOKABLE virtual void checkForUpdates() = 0;
    Q_INVOKABLE virtual void setInstallationAllowed(bool allowed);
signals:
    void error(const QString& message);
    void saveRequired();
protected:
    std::atomic_bool installationAllowed_{false};
};

// Disabled development builds return an explicit unavailable service, never an
// unsigned home-made updater. Release configuration requires a valid public key.
std::unique_ptr<UpdateService> createUpdateService();

} // namespace mokaid::updates
