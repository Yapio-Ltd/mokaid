#include <QDir>
#include <QFile>
#include <QFontDatabase>
#include <QGuiApplication>
#include <QJSValue>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QTemporaryDir>
#include <QtTest>
#include <memory>

// Authored, in-memory fixtures only: these interaction tests and screenshots
// never use an account, a running backend, or saved workspace content.
class CompletionControllerFixture final : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantMap completionNotification MEMBER notification NOTIFY changed)
    Q_PROPERTY(QVariantMap completionTask MEMBER task NOTIFY changed)
    Q_PROPERTY(bool completionLoading MEMBER loading NOTIFY changed)
    Q_PROPERTY(QString completionError MEMBER error NOTIFY changed)
    Q_PROPERTY(int pendingCompletionCount MEMBER pending NOTIFY changed)
    Q_PROPERTY(bool reducedMotion READ reducedMotion CONSTANT)
public:
    QVariantMap notification, task;
    QString error;
    bool loading = false;
    int pending = 0, dismissCount = 0, dismissAllCount = 0, retryCount = 0;
    bool reducedMotion() const { return true; }

    Q_INVOKABLE void dismissCompletion() {
        ++dismissCount;
        if (pending > 0) --pending;
        else { notification.clear(); task.clear(); }
        emit changed();
    }
    Q_INVOKABLE void dismissAllCompletions() {
        ++dismissAllCount;
        pending = 0; notification.clear(); task.clear(); emit changed();
    }
    Q_INVOKABLE void retryCompletion() { ++retryCount; loading = true; error.clear(); emit changed(); }
signals:
    void changed();
};

class CompletionPreviewFixture final : public QObject {
    Q_OBJECT
    Q_PROPERTY(int thumbnailRevision READ thumbnailRevision CONSTANT)
public:
    int thumbnailRevision() const { return 1; }
    Q_INVOKABLE QVariantMap describe(const QVariantMap& file) const {
        const bool image = file.value("mime_type").toString().startsWith("image/");
        return {{"kind", image ? "image" : "pdf"}, {"label", image ? "Image" : "PDF document"},
            {"sizeLabel", image ? "246 KB" : "84 KB"}, {"canPreview", true}};
    }
    Q_INVOKABLE QString thumbnailUrl(const QVariantMap&) const { return "qrc:/ui/portrait-design.png"; }
    Q_INVOKABLE QString thumbnailState(const QVariantMap&) const { return "ready"; }
};

class CompletionDownloadFixture final : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool busy MEMBER busy NOTIFY changed)
    Q_PROPERTY(bool pendingTransaction MEMBER pendingTransaction NOTIFY changed)
    Q_PROPERTY(QString error MEMBER error NOTIFY changed)
    Q_PROPERTY(QString status MEMBER status NOTIFY changed)
public:
    bool busy = false, pendingTransaction = false;
    QString error, status;
signals:
    void changed();
};

static QVariantList completedFiles() {
    return {QVariantMap{{"id", "fixture-image"}, {"name", "Brand direction.png"},
                {"filename", "Brand direction.png"}, {"mime_type", "image/png"}, {"size_bytes", 251904}},
        QVariantMap{{"id", "fixture-guide"}, {"name", "Brand guidelines.pdf"},
                {"filename", "Brand guidelines.pdf"}, {"mime_type", "application/pdf"}, {"size_bytes", 86016}}};
}

static QString completedResponse() {
    return QStringLiteral("Your new brand direction is ready.\n\n"
        "I created a cohesive visual identity with a warm palette, a clear typographic hierarchy, "
        "and a flexible layout system for your next campaign.\n\n"
        "The image gives you a quick look at the direction. The accompanying guide includes the "
        "colors, typography, spacing, and usage recommendations so your team can apply it consistently.\n\n"
        "You can preview both deliverables below or download them to share with your team.");
}

class CompletionView final {
public:
    CompletionControllerFixture controller;
    CompletionPreviewFixture preview;
    CompletionDownloadFixture downloads;
    QTemporaryDir directory;
    QQmlEngine engine;
    QStringList warnings;
    std::unique_ptr<QObject> root;
    QQuickWindow window;
    QString failure;

    CompletionView() {
        controller.notification = {{"id", "fixture-notification"}, {"resource_id", "fixture-brand"},
            {"title", "Create the new brand direction"}, {"inserted_at", "2026-09-27T10:42:00Z"}};
        controller.task = {{"id", "fixture-brand"}, {"title", "Create the new brand direction"},
            {"description", "Design a welcoming identity and a practical guide for the team."},
            {"status", "completed"}, {"project_name", "Launch campaign"},
            {"assigned_agent_name", "Aria"}, {"assigned_agent_id", "fixture-aria"},
            {"assigned_agent_kind", "ai"}, {"assigned_agent_avatar_cdn_path", "/assets3d/avatar_design.0123456789ab.glb"},
            {"started_at", "2026-09-27T10:40:00Z"}, {"completed_at", "2026-09-27T10:42:00Z"},
            {"latest_run", QVariantMap{{"id", "fixture-run"}, {"status", "completed"},
                {"output", QVariantMap{{"summary", completedResponse()}}}}}};
        for (const auto& name : QDir(QStringLiteral(MOKAID_COMPLETION_QML_DIRECTORY)).entryList({"*.qml", "*.js"}, QDir::Files))
            QFile::copy(QStringLiteral(MOKAID_COMPLETION_QML_DIRECTORY) + "/" + name, directory.path() + "/" + name);
        QFile qmldir(directory.path() + "/qmldir");
        if (!qmldir.open(QIODevice::WriteOnly)) { failure = "Could not write isolated QML module"; return; }
        qmldir.write("singleton Theme 1.0 Theme.qml\n"); qmldir.close();
        QObject::connect(&engine, &QQmlEngine::warnings, &engine, [this](const QList<QQmlError>& errors) {
            for (const auto& warning : errors) warnings.append(warning.toString());
        });
        engine.rootContext()->setContextProperty("fixtureController", &controller);
        engine.rootContext()->setContextProperty("system", &controller);
        engine.rootContext()->setContextProperty("preview", &preview);
        engine.rootContext()->setContextProperty("fixtureDownloads", &downloads);
        engine.rootContext()->setContextProperty("fixtureFiles", completedFiles());
        QQmlComponent component(&engine);
        component.setData(R"QML(
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic as Basic
Rectangle {
    id: root
    anchors.fill: parent
    width: 1440; height: 900; color: "#090b13"
    Basic.Button {
        id: anchor; objectName: "completionAnchor"
        x: 28; y: 28; text: "Workspace"
        onClicked: completion.open()
    }
    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom; anchors.bottomMargin: 9
        text: "INTERFACE TEST · SYNTHETIC DATA"
        font.family: Theme.fontFamily; font.pixelSize: 10; font.letterSpacing: 1
        color: "#c0c8d8"
    }
    TaskCompletionDialog {
        id: completion; objectName: "completionDialog"
        controller: fixtureController
        files: fixtureFiles
        downloadManager: fixtureDownloads
        reducedMotion: true
    }
    Connections {
        target: fixtureController
        function onChanged() {
            if (!fixtureController.completionNotification.id) completion.close()
        }
    }
}
)QML", QUrl::fromLocalFile(directory.path() + "/CompletionFixture.qml"));
        root.reset(component.create()); failure = component.errorString();
        if (auto* rootItem = qobject_cast<QQuickItem*>(root.get())) {
            rootItem->setParentItem(window.contentItem());
            window.setColor(QColor("#090b13")); resize(1440, 900); window.show(); window.requestActivate();
        }
    }
    ~CompletionView() { if (auto* item = qobject_cast<QQuickItem*>(root.get())) item->setParentItem(nullptr); }
    void polish() { QCoreApplication::processEvents(); window.grabWindow(); }
    void resize(int width, int height) {
        window.resize(width, height);
        polish();
    }
    QList<QQuickItem*> items() const {
        QList<QQuickItem*> result{window.contentItem()};
        for (qsizetype index = 0; index < result.size(); ++index) result.append(result.at(index)->childItems());
        return result;
    }
    QObject* object(const QString& name) const {
        if (root) if (auto* object = root->findChild<QObject*>(name)) return object;
        for (auto* child : items()) if (child->objectName() == name) return child;
        return nullptr;
    }
    QQuickItem* item(const QString& name) const { return qobject_cast<QQuickItem*>(object(name)); }
    QObject* dialog() const { return object("completionDialog"); }
    bool visible() const { return dialog() && dialog()->property("visible").toBool(); }
    bool inside(const QString& name) const {
        auto* control = item(name);
        if (!control || !control->isVisible() || control->width() <= 0 || control->height() <= 0) return false;
        const auto bounds = control->mapRectToScene(QRectF(0, 0, control->width(), control->height()));
        return bounds.left() >= -1 && bounds.top() >= -1
            && bounds.right() <= window.width() + 1 && bounds.bottom() <= window.height() + 1;
    }
    bool click(const QString& name) {
        polish(); auto* control = item(name);
        if (!control || !control->isVisible()) return false;
        QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier,
            control->mapToScene(QPointF(control->width() / 2, control->height() / 2)).toPoint());
        polish(); return true;
    }
    bool reveal(const QString& name) {
        polish(); auto* control = item(name); if (!control) return false;
        for (auto* ancestor = control->parentItem(); ancestor; ancestor = ancestor->parentItem()) {
            if (ancestor->metaObject()->indexOfProperty("contentY") < 0) continue;
            const auto offset = control->mapToItem(ancestor, QPointF(0, control->height() / 2)).y() - ancestor->height() / 2;
            const auto limit = qMax(0., ancestor->property("contentHeight").toReal() - ancestor->height());
            ancestor->setProperty("contentY", qBound(0., ancestor->property("contentY").toReal() + offset, limit));
            polish();
        }
        return inside(name);
    }
    bool hasText(const QString& value) const {
        for (auto* child : items()) if (child->isVisible() && child->property("text").toString().contains(value)) return true;
        return false;
    }
    bool capture(const QString& name) {
        const auto output = qEnvironmentVariable("MOKAID_COMPLETION_CAPTURE_DIR");
        if (output.isEmpty()) return true;
        polish(); QDir().mkpath(output); return window.grabWindow().save(output + "/" + name + ".png");
    }
};

class CompletionQmlTests final : public QObject {
    Q_OBJECT
private slots:
    void resultAndDeliverablesFitAtReferenceAndCompactSizes() {
        CompletionView view; QVERIFY2(view.root, qPrintable(view.failure));
        QVERIFY(view.click("completionAnchor")); QTRY_VERIFY(view.visible());
        QTRY_VERIFY(view.item("completionResponse"));
        QCOMPARE(view.item("completionPortrait")->property("portraitSource").toString(), QString("qrc:/ui/portrait-design.png"));
        QCOMPARE(view.item("completionResponse")->property("text").toString(), completedResponse());
        QVERIFY(view.item("completionResponse")->property("readOnly").toBool());
        QVERIFY(view.item("completionResponse")->property("selectByMouse").toBool());
        for (const QSize size : {QSize(1440, 900), QSize(1000, 680)}) {
            view.resize(size.width(), size.height()); QTest::qWait(80);
            for (const auto* name : {"completionClose", "completionTask"})
                QVERIFY2(view.inside(name), qPrintable(QString("%1 is clipped at %2×%3").arg(name).arg(size.width()).arg(size.height())));
            QVERIFY(view.capture(QString("completion-%1").arg(size.width())));
            for (const auto* name : {"completionPreview_0", "completionDownload_0", "completionPreview_1", "completionDownload_1"})
                QVERIFY2(view.reveal(name), qPrintable(QString("Cannot reach %1 at %2×%3").arg(name).arg(size.width()).arg(size.height())));
        }
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }

    void previewDownloadAndTaskActionsRouteTheirExactTargets() {
        CompletionView view; QVERIFY2(view.root, qPrintable(view.failure));
        QSignalSpy previews(view.dialog(), SIGNAL(previewRequested(int)));
        QSignalSpy downloads(view.dialog(), SIGNAL(downloadRequested(QVariant)));
        QSignalSpy tasks(view.dialog(), SIGNAL(taskRequested(QString)));
        QVERIFY(previews.isValid()); QVERIFY(downloads.isValid()); QVERIFY(tasks.isValid());
        QVERIFY(view.click("completionAnchor")); QTRY_VERIFY(view.visible());
        QVERIFY(view.reveal("completionPreview_0")); QVERIFY(view.click("completionPreview_0"));
        QCOMPARE(previews.count(), 1); QCOMPARE(previews.first().first().toInt(), 0);
        QVERIFY(view.reveal("completionDownload_1")); QVERIFY(view.click("completionDownload_1"));
        QCOMPARE(downloads.count(), 1);
        const auto delivered = downloads.first().first();
        const auto file = delivered.metaType() == QMetaType::fromType<QJSValue>() ? delivered.value<QJSValue>().toVariant().toMap() : delivered.toMap();
        QCOMPARE(file.value("id").toString(), QString("fixture-guide"));
        view.downloads.busy = true; emit view.downloads.changed();
        QTRY_VERIFY(!view.item("completionDownload_1")->isEnabled());
        QVERIFY(view.click("completionDownload_1")); QCOMPARE(downloads.count(), 1);
        view.downloads.busy = false; view.downloads.pendingTransaction = true; emit view.downloads.changed();
        QTRY_VERIFY(!view.item("completionDownload_1")->isEnabled());
        view.downloads.pendingTransaction = false;
        view.downloads.error = "The download could not be saved. Please try again."; emit view.downloads.changed();
        QTRY_VERIFY(view.item("completionDownload_1")->isEnabled());
        QVERIFY(view.hasText(view.downloads.error));
        QVERIFY(view.click("completionTask")); QCOMPARE(tasks.count(), 1);
        QCOMPARE(tasks.first().first().toString(), QString("fixture-brand"));
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }

    void queueCanAdvanceAndEscapeDismissesRemainingResultsAndRestoresFocus() {
        CompletionView view; QVERIFY2(view.root, qPrintable(view.failure));
        QSignalSpy acknowledged(view.dialog(), SIGNAL(resultAcknowledged())); QVERIFY(acknowledged.isValid());
        view.controller.pending = 2; emit view.controller.changed();
        view.item("completionAnchor")->forceActiveFocus();
        QTRY_VERIFY(view.item("completionAnchor")->hasActiveFocus());
        QVERIFY(view.click("completionAnchor")); QTRY_VERIFY(view.visible());
        QVERIFY(view.hasText("2 more results are ready"));
        QTRY_VERIFY(view.item("completionNext")); QVERIFY(view.inside("completionNext"));
        QVERIFY(view.click("completionNext")); QCOMPARE(view.controller.dismissCount, 1);
        QCOMPARE(acknowledged.count(), 1);
        QCOMPARE(view.controller.pending, 1); QVERIFY(view.visible());
        QVERIFY(view.hasText("1 more result is ready"));
        QTest::keyClick(&view.window, Qt::Key_Escape);
        QTRY_COMPARE(view.controller.dismissAllCount, 1);
        QCOMPARE(acknowledged.count(), 1);
        QTRY_VERIFY(!view.visible());
        QTRY_VERIFY(view.item("completionAnchor")->hasActiveFocus());
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }

    void loadingErrorAndMissingResponseRemainUsable() {
        CompletionView view; QVERIFY2(view.root, qPrintable(view.failure));
        view.controller.loading = true; view.controller.task.clear(); emit view.controller.changed();
        QVERIFY(view.dialog()->setProperty("files", QVariantList{}));
        QVERIFY(view.click("completionAnchor")); QTRY_VERIFY(view.visible());
        view.resize(1000, 680); QVERIFY(view.inside("completionClose"));
        QVERIFY(view.capture("completion-loading-1000"));
        view.controller.loading = false; view.controller.error = "The result could not be loaded. Please try again.";
        emit view.controller.changed();
        QTRY_VERIFY(view.item("completionRetry") && view.item("completionRetry")->isVisible());
        QVERIFY(view.hasText(view.controller.error)); QVERIFY(view.capture("completion-error-1000"));
        QVERIFY(view.click("completionRetry")); QCOMPARE(view.controller.retryCount, 1);
        view.controller.loading = false; view.controller.error.clear();
        view.controller.task = {{"id", "fixture-brand"}, {"title", "Create the new brand direction"}, {"status", "completed"}};
        emit view.controller.changed(); view.polish();
        QVERIFY(view.inside("completionClose")); QVERIFY(view.inside("completionTask"));
        QVERIFY(!view.item("completionPreview_0") || !view.item("completionPreview_0")->isVisible());
        QVERIFY(view.capture("completion-no-response-1000"));
        QVERIFY(view.click("completionClose")); QTRY_VERIFY(!view.visible());
        QCOMPARE(view.controller.dismissAllCount, 1);
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }

    void longResponseIsCompleteSelectableAndNeverInterpretedAsMarkup() {
        CompletionView view; QVERIFY2(view.root, qPrintable(view.failure));
        const auto response = QString("Literal content: <b>keep these tags</b> & <script>never execute</script>\n\n")
            + QString("A detailed recommendation with every point preserved and available for selection.\n").repeated(80)
            + "Final recommendation: review the complete report.";
        view.controller.task.insert("latest_run", QVariantMap{{"status", "completed"}, {"output", QVariantMap{{"summary", response}}}});
        emit view.controller.changed();
        QVERIFY(view.click("completionAnchor")); QTRY_VERIFY(view.visible()); view.resize(1000, 680);
        QTRY_VERIFY(view.item("completionResponse"));
        auto* text = view.item("completionResponse");
        QCOMPARE(text->property("text").toString(), response);
        QCOMPARE(text->property("textFormat").toInt(), int(Qt::PlainText));
        QVERIFY(QMetaObject::invokeMethod(text, "selectAll"));
        QCOMPARE(text->property("selectedText").toString(), response);
        QVERIFY(QMetaObject::invokeMethod(text, "deselect"));
        QVERIFY(view.inside("completionClose")); QVERIFY(view.inside("completionTask"));
        QVERIFY(view.reveal("completionPreview_0")); QVERIFY(view.reveal("completionDownload_1"));
        QVERIFY(view.capture("completion-long-response-1000"));
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }
};

int main(int argc, char** argv) {
    if (qEnvironmentVariableIsSet("MOKAID_COMPLETION_NATIVE_CAPTURE")) {
#ifdef Q_OS_MACOS
        QQuickWindow::setGraphicsApi(QSGRendererInterface::Metal);
#elif defined(Q_OS_WIN)
        QQuickWindow::setGraphicsApi(QSGRendererInterface::Direct3D11);
#endif
    } else {
        qputenv("QT_QPA_PLATFORM", "offscreen");
        QQuickWindow::setGraphicsApi(QSGRendererInterface::Software);
    }
    QQuickStyle::setStyle("Basic");
    QGuiApplication app(argc, argv);
    QFontDatabase::addApplicationFont(QStringLiteral(MOKAID_COMPLETION_QML_DIRECTORY) + "/../assets/fonts/Manrope.ttf");
    app.setFont(QFont("Manrope"));
    CompletionQmlTests tests; return QTest::qExec(&tests, argc, argv);
}
#include "completion_qml_tests.moc"
