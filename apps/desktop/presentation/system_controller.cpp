#include <mokaid/presentation/system_controller.hpp>
#include <QCoreApplication>
#include <QDateTime>
#include <QDesktopServices>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>
#include <QSysInfo>
#include <cmath>
namespace mokaid::desktop {
SystemController::SystemController(QString assets, QObject* parent) : QObject(parent), assets_(std::move(assets)) {}
QString SystemController::version() const { return QCoreApplication::applicationVersion(); }
QString SystemController::productName() const { return QCoreApplication::applicationName(); }
void SystemController::setReducedMotion(bool value) { settings_.setValue("accessibility/reducedMotion", value); emit changed(); }
void SystemController::setSoftwareWeb(bool value) { settings_.setValue("web/software", value); emit changed(); }
void SystemController::setQuality(const QString& value) {
    if (value != "auto" && value != "high" && value != "medium" && value != "low") return;
    settings_.setValue("graphics/quality", value); emit changed();
}
bool SystemController::exportDiagnostics(const QUrl& destination, const QVariantMap& graphics, const QVariantMap& presentation) {
    if (!destination.isLocalFile()) return false;
    // Explicit metric allowlist: no URLs, user names, workspace content, tokens, or message logs.
    QJsonObject safeGraphics;
    for (const auto& name : {"assetBytes", "textureBytes", "renderCpuMs", "renderWidth", "renderHeight", "scale", "drawCalls", "triangles"}) {
        const auto value = graphics.value(name);
        bool numeric = false; const double number = value.toDouble(&numeric);
        if (numeric && std::isfinite(number)) safeGraphics[name] = number;
    }
    QJsonObject safePresentation;
    for (const auto& name : {"sampleCount", "windowSeconds", "lastFrameAgeSeconds", "meanMs", "maxMs", "p50Ms", "p95Ms", "p99Ms"}) {
        bool numeric = false; const double number = presentation.value(name).toDouble(&numeric);
        if (numeric && std::isfinite(number)) safePresentation[name] = number;
    }
    const QJsonObject data{{"schema", 1}, {"version", version()}, {"qt", qVersion()},
        {"os", QSysInfo::prettyProductName()}, {"architecture", QSysInfo::currentCpuArchitecture()},
        {"generatedAt", QDateTime::currentDateTimeUtc().toString(Qt::ISODate)},
        {"graphics", safeGraphics}, {"presentationIntervals", safePresentation}, {"softwareWeb", softwareWeb()}, {"quality", quality()}};
    QSaveFile file(destination.toLocalFile());
    if (!file.open(QIODevice::WriteOnly) || file.write(QJsonDocument(data).toJson()) < 0 || !file.commit()) {
        error_ = file.errorString(); emit changed(); return false;
    }
    error_.clear(); emit changed(); return true;
}
void SystemController::openBrowser(const QUrl& url) {
    if (url.isValid() && url.scheme() == "https" && url.userInfo().isEmpty()) QDesktopServices::openUrl(url);
}
}
