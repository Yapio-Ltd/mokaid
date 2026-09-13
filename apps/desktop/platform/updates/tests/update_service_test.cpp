#include <mokaid/updates/update_service.hpp>
#include <QCoreApplication>
#include <QMetaObject>
#include <iostream>

int main(int argc, char** argv) {
    QCoreApplication app(argc, argv);
    auto updater = mokaid::updates::createUpdateService();
    if (updater->available() != bool(MOKAID_TEST_UPDATES_ENABLED) || updater->installationAllowed()) {
        std::cerr << "Updater availability or closed installation gate is incorrect\n";
        return 1;
    }
    if (!QMetaObject::invokeMethod(updater.get(), "setInstallationAllowed", Q_ARG(bool, true)) ||
        !updater->installationAllowed()) {
        std::cerr << "The QML installation gate is not invokable\n";
        return 1;
    }
    updater->setInstallationAllowed(false);
    if (updater->installationAllowed()) return 1;
    if (updater->channel() != QStringLiteral("stable") && updater->channel() != QStringLiteral("beta")) return 1;
#if !MOKAID_TEST_UPDATES_ENABLED
    int errors = 0;
    QObject::connect(updater.get(), &mokaid::updates::UpdateService::error,
                     [&errors](const QString& message) { if (!message.isEmpty()) ++errors; });
    updater->startup();
    if (errors != 0) return 1;
    updater->checkForUpdates();
    if (errors != 1) return 1;
#endif
    // SDK-enabled tests deliberately avoid contacting a real update feed or
    // opening a system updater dialog; signed installation is a separate gate.
    return 0;
}
