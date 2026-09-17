#include <mokaid/application/office_controller.hpp>
#include <mokaid/application/artifact_service.hpp>
#include <mokaid/application/activity_controller.hpp>
#include <mokaid/application/mission_controller.hpp>
#include <mokaid/application/orchestrator_controller.hpp>
#include <mokaid/voice/voice_controller.hpp>
#include <mokaid/features/feature_controller.hpp>
#include <mokaid/presentation/system_controller.hpp>
#include <mokaid/presentation/frame_profiler.hpp>
#include <mokaid/presentation/project_runtime.hpp>
#include <mokaid/preview/preview_controller.hpp>
#include <mokaid/updates/update_service.hpp>
#include <native_viewport.hpp>
#include <QCommandLineParser>
#include <QDir>
#include <QGuiApplication>
#include <QIcon>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QSettings>
#include <QStandardPaths>
#include <QtWebEngineQuick>

int main(int argc, char* argv[]) {
    using namespace mokaid::desktop;
    const bool beta = QByteArray(MOKAID_RELEASE_CHANNEL) == "beta";
    const bool development = MOKAID_DEVELOPMENT;
    QCoreApplication::setOrganizationName("Mokaid");
    QCoreApplication::setOrganizationDomain(development ? "com.mokaid.desktop.development" : beta ? "com.mokaid.desktop.beta" : "com.mokaid.desktop");
    QCoreApplication::setApplicationName(development ? "Mokaid Development" : beta ? "Mokaid Beta" : "Mokaid");
    QCoreApplication::setApplicationVersion(MOKAID_RELEASE_VERSION);
    if (QSettings().value("web/software", false).toBool())
        qputenv("QTWEBENGINE_CHROMIUM_FLAGS", "--disable-gpu --disable-gpu-compositing");
#ifdef Q_OS_MACOS
    if (qEnvironmentVariableIsEmpty("QT_MEDIA_BACKEND")) qputenv("QT_MEDIA_BACKEND", "darwin");
    QQuickWindow::setGraphicsApi(QSGRendererInterface::Metal);
#elif defined(Q_OS_WIN)
    QQuickWindow::setGraphicsApi(QSGRendererInterface::Direct3D11);
#endif
    PreviewController::registerScheme();
    QtWebEngineQuick::initialize();
    QGuiApplication app(argc, argv);
    QQuickStyle::setStyle("Basic");
    app.setWindowIcon(QIcon(":/branding/logo-with-bg.png"));
    QCommandLineParser parser; parser.setApplicationDescription("Mokaid — native AI workspace");
    parser.addHelpOption(); parser.addVersionOption();
    parser.addOption({"assets", "Cooked .mokaidasset directory", "directory"});
    parser.process(app);
    QString assets = parser.value("assets");
    if (assets.isEmpty()) {
        assets = QCoreApplication::applicationDirPath() + "/assets";
#ifdef Q_OS_MACOS
        assets = QCoreApplication::applicationDirPath() + "/../Resources/assets";
#endif
        if (!QDir(assets).exists()) assets = QStringLiteral(MOKAID_DEV_ASSETS);
    }
    ApiClient api{QUrl(QStringLiteral(MOKAID_API_ORIGIN))};
    PhoenixClient realtime;
    CacheStore cache(QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation) + "/cache");
    SessionController session(api, realtime, nullptr, QUrl(QStringLiteral(MOKAID_WEB_ORIGIN)));
    OfficeController office(api, session, realtime, cache);
    ActivityController activity(api, session, realtime, cache);
    MissionController missions(api, session, realtime, activity);
    OrchestratorController orchestrator(api, session, realtime, cache, missions);
    VoiceController voice;
    FeatureController features(api, session, cache);
    ArtifactService artifacts(api, session, cache);
    PreviewController preview(artifacts);
    SystemController system(assets);
    FrameProfiler profiler;
    ProjectRuntime projectRuntime;
    auto updates = mokaid::updates::createUpdateService();
    QObject::connect(&session, &SessionController::cleared, &preview, &PreviewController::clear);
    QObject::connect(&session, &SessionController::workspaceChanged, &preview, &PreviewController::clear);
    QObject::connect(&session, &SessionController::cleared, &projectRuntime, &ProjectRuntime::clear);
    QObject::connect(&session, &SessionController::workspaceChanged, &projectRuntime, &ProjectRuntime::clear);
    QObject::connect(&session, &SessionController::cleared, &voice, &VoiceController::cancel);
    QObject::connect(&session, &SessionController::workspaceChanged, &voice, &VoiceController::cancel);
    QObject::connect(&orchestrator, &OrchestratorController::openTask, &features, [&features, &preview](const QString& id) { preview.setVisible(false); features.openRecord("tasks", id); });
    QObject::connect(&missions, &MissionController::launched, &office, [&office](const QString&, const QString&) { office.refresh(); });
    QObject::connect(&missions, &MissionController::launched, &features, [&features](const QString&, const QString&) { features.refresh(); });
    QObject::connect(&features, &FeatureController::openDelivery, &preview, &PreviewController::openFile);
    QObject::connect(&preview, &PreviewController::downloadRequested, &features, [&features](const QVariantMap& file) {
        static_cast<DriveDownload*>(features.driveDownload())->request(file);
    });
    QObject::connect(&features, &FeatureController::requestExternal, &system, &SystemController::openBrowser);
    QObject::connect(&realtime, &PhoenixClient::rejoined, &features, &FeatureController::refresh);
    QObject::connect(&activity, &ActivityController::navigateRequested, &features, &FeatureController::openRecord);
    mokaid::registerViewportTypes();
    qmlRegisterUncreatableType<PreviewDocument>("Mokaid.Preview", 1, 0, "PreviewDocument", "Owned by PreviewController");
    QQmlApplicationEngine engine;
    for (const auto& entry : {std::pair{"session", static_cast<QObject*>(&session)}, {"office", &office},
             {"features", &features}, {"activity", &activity}, {"missions", &missions}, {"orchestrator", &orchestrator}, {"voice", &voice}, {"projectRuntime", &projectRuntime}, {"preview", &preview}, {"system", &system}, {"profiler", &profiler}, {"updates", updates.get()}})
        engine.rootContext()->setContextProperty(QString::fromLatin1(entry.first), entry.second);
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app, [] { QCoreApplication::exit(1); }, Qt::QueuedConnection);
    engine.loadFromModule("Mokaid.Desktop", "Main");
    for (auto* root : engine.rootObjects())
        if (auto* window = qobject_cast<QQuickWindow*>(root)) { profiler.attach(window); break; }
    QTimer::singleShot(0, &session, &SessionController::restore);
    QTimer::singleShot(0, updates.get(), &mokaid::updates::UpdateService::startup);
    return app.exec();
}
