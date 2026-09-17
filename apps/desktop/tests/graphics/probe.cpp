#include <mokaid/preview/preview_controller.hpp>
#include <native_viewport.hpp>
#include <QCommandLineParser>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMutex>
#include <QMutexLocker>
#include <QPointer>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QScreen>
#include <QSysInfo>
#include <QTemporaryFile>
#include <QTimer>
#include <QtWebEngineQuick>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <iostream>
#include <memory>
#include <vector>

using mokaid::desktop::PreviewDocument;

class GraphicsProbe final : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString assetRoot READ assetRoot CONSTANT)
    Q_PROPERTY(QVariantList fixtureAgents READ fixtureAgents CONSTANT)
    Q_PROPERTY(PreviewDocument* document READ document CONSTANT)
    Q_PROPERTY(bool nativePreviewAvailable READ nativePreviewAvailable CONSTANT)
public:
    bool nativePreviewAvailable() const { return false; }
    GraphicsProbe(QString assets, QString output, QString machine, QByteArray fixture)
        : assets_(std::move(assets)), output_(std::move(output)), machine_(std::move(machine)),
          document_(std::make_unique<PreviewDocument>(QVariantMap{{"name", "graphics-fixture.html"},
                    {"mime_type", "text/html"}, {"version", "test-only"}}, std::move(fixture))) {}
    QString assetRoot() const { return assets_; }
    PreviewDocument* document() const { return document_.get(); }
    QVariantList fixtureAgents() const {
        QVariantList agents;
        const QStringList avatars{"male", "female", "corporate", "developer", "design", "finance", "research", "legal"};
        for (qsizetype i = 0; i < avatars.size(); ++i)
            agents.append(QVariantMap{{"id", QString("graphics-fixture-%1").arg(i)},
                {"name", "Test fixture " + avatars[i]}, {"status", i % 2 ? "working" : "walking"},
                {"asset_type", avatars[i]}, {"seat_index", i}});
        return agents;
    }
    void attachWindow(QQuickWindow* window) {
        window_ = window;
        connect(window, &QWindow::activeChanged, this, [this] {
            const QMutexLocker lock(&mutex_);
            if (measuring_ && window_ && !window_->isActive()) focusInterrupted_ = true;
        });
        connect(window, &QQuickWindow::frameSwapped, this, [this] {
            totalFrames_.fetch_add(1, std::memory_order_relaxed);
            const auto now = Clock::now();
            const QMutexLocker lock(&mutex_);
            if (!measuring_) return;
            if (lastFrame_ == Clock::time_point{})
                firstFrameDelayMs_ = std::chrono::duration<double, std::milli>(now - measurementStart_).count();
            if (lastFrame_ != Clock::time_point{})
                frames_.push_back(std::chrono::duration<double, std::milli>(now - lastFrame_).count());
            lastFrame_ = now;
        }, Qt::DirectConnection);
    }
    Q_INVOKABLE bool check(const QString& name, bool passed) {
        if (done_) return false;
        checks_.append(QJsonObject{{"name", name}, {"passed", passed}});
        if (!passed) fail("Assertion failed: " + name);
        return passed;
    }
    Q_INVOKABLE qulonglong composedFrames() const { return totalFrames_.load(std::memory_order_relaxed); }
    Q_INVOKABLE void openExternal(const QUrl& url) {
        // A recording test double, never QDesktopServices: the test cannot open
        // links outside its fixture or navigate the real user's browser.
        if (url.scheme() == "https" && url.isValid() && url.userInfo().isEmpty()) ++externalRequests_;
    }
    Q_INVOKABLE void beginMeasurements() {
        const QMutexLocker lock(&mutex_);
        frames_.clear(); lastFrame_ = {}; measurementStart_ = Clock::now(); measuring_ = true;
        firstFrameDelayMs_ = 0; focusInterrupted_ = !window_ || !window_->isActive();
    }
    Q_INVOKABLE void finish(const QVariantMap& renderer) {
        if (done_) return;
        renderer_ = renderer;
        std::vector<double> samples;
        {
            const QMutexLocker lock(&mutex_);
            measurementDurationMs_ = std::chrono::duration<double, std::milli>(Clock::now() - measurementStart_).count();
            measuring_ = false; samples = frames_;
        }
        if (!check("post-warmup-frame-sample-count", samples.size() >= 60)) return;
        if (!check("no-external-browser-launch", externalRequests_ == 0)) return;
        if (!check("no-native-renderer-error", window_ && renderer.value("triangles").toULongLong() > 0)) return;
        done_ = true;
        writeResult(true, samples);
    }
    Q_INVOKABLE void fail(const QString& message) {
        if (done_) return;
        done_ = true; failure_ = message;
        std::vector<double> samples;
        { const QMutexLocker lock(&mutex_); measuring_ = false; samples = frames_; }
        writeResult(false, samples);
    }
private:
    using Clock = std::chrono::steady_clock;
    static double percentile(std::vector<double> samples, double quantile) {
        if (samples.empty()) return 0;
        std::sort(samples.begin(), samples.end());
        const auto index = static_cast<std::size_t>(std::ceil(quantile * static_cast<double>(samples.size()))) - 1;
        return samples[std::min(index, samples.size() - 1)];
    }
    void writeResult(bool passed, const std::vector<double>& samples) {
        QDir().mkpath(output_);
        const auto screenshot = QDir(output_).absoluteFilePath("native-webengine.png");
        // Only the test captures a CPU image, after measurement. Production's
        // renderer still presents its GPU texture directly without readback.
        const bool captured = window_ && window_->grabWindow().save(screenshot);
        if (passed && !captured) { passed = false; failure_ = "Could not capture the integration screenshot"; }
        QJsonArray frames;
        double totalMs = 0;
        for (double value : samples) { frames.append(value); totalMs += value; }
        auto* screen = window_ ? window_->screen() : nullptr;
        QFile assetManifest(assets_ + "/manifest.json");
        const auto assetDigest = assetManifest.open(QIODevice::ReadOnly)
            ? QString::fromLatin1(QCryptographicHash::hash(assetManifest.readAll(), QCryptographicHash::Sha256).toHex()) : QString{};
        const QJsonObject result{{"schemaVersion", 1}, {"status", passed ? "passed" : "failed"},
            {"scope", "Native scene + production HTML integration only; not product parity or target-device acceptance"},
            {"failure", failure_}, {"machineLabel", machine_}, {"os", QSysInfo::prettyProductName()},
            {"cpuArchitecture", QSysInfo::currentCpuArchitecture()}, {"qtVersion", qVersion()},
            {"assetManifestSha256", assetDigest},
            {"recordedAt", QDateTime::currentDateTimeUtc().toString(Qt::ISODate)},
            {"warmupMs", 5000}, {"requestedSampleWindowMs", 10000}, {"actualSampleWindowMs", measurementDurationMs_},
            {"firstFrameDelayMs", firstFrameDelayMs_}, {"focusInterrupted", focusInterrupted_},
            {"sanitizerInstrumented", bool(MOKAID_PROBE_INSTRUMENTED)},
            {"performanceSampleQualified", !MOKAID_PROBE_INSTRUMENTED && !focusInterrupted_ && firstFrameDelayMs_ < 100 && measurementDurationMs_ >= 9500},
            {"frameMetric", "QQuickWindow frameSwapped wall-clock intervals, not GPU timestamps"},
            {"frameCount", static_cast<qint64>(samples.size())}, {"frameP50Ms", percentile(samples, .50)},
            {"frameP95Ms", percentile(samples, .95)}, {"frameP99Ms", percentile(samples, .99)},
            {"frameMaxMs", samples.empty() ? 0 : *std::max_element(samples.begin(), samples.end())},
            {"frameMeanMs", samples.empty() ? 0 : totalMs / static_cast<double>(samples.size())},
            {"frameIntervalsMs", frames}, {"renderer", QJsonObject::fromVariantMap(renderer_)},
            {"screenRefreshHz", screen ? screen->refreshRate() : 0},
            {"devicePixelRatio", window_ ? window_->effectiveDevicePixelRatio() : 0},
            {"windowWidth", window_ ? window_->width() : 0}, {"windowHeight", window_ ? window_->height() : 0},
            {"checks", checks_}, {"screenshot", captured ? screenshot : QString{}}};
        QFile report(QDir(output_).absoluteFilePath("report.json"));
        if (!report.open(QIODevice::WriteOnly) || report.write(QJsonDocument(result).toJson()) < 0) passed = false;
        report.close();
        auto summary = result;
        summary.remove("frameIntervalsMs"); // Full samples remain in report.json.
        std::cout << QJsonDocument(summary).toJson(QJsonDocument::Compact).constData() << '\n';
        QTimer::singleShot(0, QCoreApplication::instance(), [passed] { QCoreApplication::exit(passed ? 0 : 1); });
    }
    const QString assets_, output_, machine_;
    const std::unique_ptr<PreviewDocument> document_;
    QPointer<QQuickWindow> window_;
    QMutex mutex_;
    bool measuring_{}, done_{};
    Clock::time_point lastFrame_{};
    Clock::time_point measurementStart_{};
    double measurementDurationMs_{}, firstFrameDelayMs_{};
    bool focusInterrupted_{};
    std::vector<double> frames_;
    QJsonArray checks_;
    QVariantMap renderer_;
    QString failure_;
    int externalRequests_{};
    std::atomic<qulonglong> totalFrames_{};
};

int main(int argc, char** argv) {
    std::cerr << "Graphics probe: initializing native backends (test fixture only)\n";
#ifdef Q_OS_MACOS
    QQuickWindow::setGraphicsApi(QSGRendererInterface::Metal);
#elif defined(Q_OS_WIN)
    QQuickWindow::setGraphicsApi(QSGRendererInterface::Direct3D11);
#endif
    mokaid::desktop::PreviewController::registerScheme();
    QtWebEngineQuick::initialize();
    QGuiApplication app(argc, argv);
    QCoreApplication::setApplicationName("Mokaid Graphics Probe — test only");
    QQuickStyle::setStyle("Basic");
    QCommandLineParser args;
    args.addHelpOption();
    args.addOption({"assets", "Real cooked office asset directory", "directory"});
    args.addOption({"output", "Screenshot and machine-readable report directory", "directory"});
    args.addOption({"machine-label", "Physical host description; never substitute the target M1/Iris Xe", "description", "Uncharacterized test host"});
    args.process(app);
    if (!QFile::exists(args.value("assets") + "/manifest.json") || args.value("output").isEmpty()) {
        std::cerr << "An existing --assets manifest and --output directory are required\n"; return 2;
    }
    QFile fixture(":/probe/fixture.html");
    if (!fixture.open(QIODevice::ReadOnly)) return 2;
    QTemporaryFile forbidden(QDir::tempPath() + "/mokaid-probe-local-XXXXXX.txt");
    if (!forbidden.open() || forbidden.write("Harmless integration test marker; preview must not read this file.") < 0) return 2;
    forbidden.flush();
    QByteArray content = fixture.readAll();
    const auto fileUrl = QJsonDocument(QJsonArray{QUrl::fromLocalFile(forbidden.fileName()).toString()}).toJson(QJsonDocument::Compact);
    content.replace("LOCAL_FILE_URL", fileUrl.mid(1, fileUrl.size() - 2));
    GraphicsProbe probe(QDir(args.value("assets")).absolutePath(), QDir(args.value("output")).absolutePath(),
                        args.value("machine-label"), std::move(content));
    mokaid::registerViewportTypes();
    qmlRegisterUncreatableType<PreviewDocument>("Mokaid.Preview", 1, 0, "PreviewDocument", "Owned by the integration fixture");
    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("probe", &probe);
    engine.rootContext()->setContextProperty("preview", &probe);
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &probe,
                     [&probe] { probe.fail("Graphics probe QML could not be created"); }, Qt::QueuedConnection);
    engine.loadFromModule("Mokaid.GraphicsProbe", "Harness");
    if (!engine.rootObjects().isEmpty()) probe.attachWindow(qobject_cast<QQuickWindow*>(engine.rootObjects().first()));
    QTimer::singleShot(90000, &probe, [&probe] { probe.fail("Graphics integration timed out after 90 seconds"); });
    return app.exec();
}

#include "probe.moc"
