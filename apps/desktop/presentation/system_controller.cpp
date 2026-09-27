#include <mokaid/presentation/system_controller.hpp>
#include <QCoreApplication>
#include <QDateTime>
#include <QDesktopServices>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>
#include <QSoundEffect>
#include <QSysInfo>
#include <QGuiApplication>
#include <QWindow>
#include <cmath>

static void initializeCompletionSound() {
    // Explicitly retain this resource when the presentation static library is linked.
    static const bool initialized = [] {
        Q_INIT_RESOURCE(mokaid_completion_sounds);
        return true;
    }();
    Q_UNUSED(initialized);
}

namespace mokaid::desktop {
SystemController::SystemController(QString assets, QObject* parent) : QObject(parent), assets_(std::move(assets)) {
    initializeCompletionSound();
    completionSound_ = new QSoundEffect(this);
    completionSound_->setLoopCount(1);
    completionSound_->setVolume(0.45f);
    completionSound_->setSource(QUrl(QStringLiteral("qrc:/sounds/mission-complete.wav")));
}
void SystemController::setMissionSound(bool value) {
    settings_.setValue("notifications/missionSound", value);
    if (!value) completionSound_->stop();
    emit changed();
}
void SystemController::notifyMission() {
    for (auto* window : QGuiApplication::topLevelWindows()) {
        if (window->isVisible()) { window->alert(5000); break; }
    }
    // Closely spaced completions share a chime instead of restarting or stacking it.
    if (missionSound() && !completionSound_->isPlaying()) completionSound_->play();
}
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
void SystemController::openMailLink(const QUrl& url) {
    if(!url.isValid() || !url.userInfo().isEmpty()) return;
    if((url.scheme()=="https" || url.scheme()=="http") && !url.host().isEmpty()) QDesktopServices::openUrl(url);
    else if(url.scheme()=="mailto" && !url.path().isEmpty() && !url.hasQuery() && !url.hasFragment()) QDesktopServices::openUrl(url);
}
void SystemController::openBrowser(const QUrl& url) {
    if (url.isValid() && url.scheme() == "https" && url.userInfo().isEmpty()) QDesktopServices::openUrl(url);
}
}
