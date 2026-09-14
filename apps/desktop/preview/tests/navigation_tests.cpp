#include <mokaid/preview/preview_controller.hpp>
#include <QFile>
#include <QGuiApplication>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QTemporaryDir>
#include <QtTest>
#include <QtWebEngineQuick>

using namespace mokaid::desktop;

class PreviewNavigationTests final : public QObject {
    Q_OBJECT
private slots:
    void filesButtonRequestsNativeNavigationWithoutEvictingPreviewState() {
        QTemporaryDir qmlDirectory, cacheDirectory;
        QVERIFY(qmlDirectory.isValid()); QVERIFY(cacheDirectory.isValid());
        for (const auto* name : {"PreviewPanel.qml", "DeliveryView.qml", "Theme.qml", "MokaidLabel.qml", "MokaidButton.qml"})
            QVERIFY(QFile::copy(QStringLiteral(MOKAID_PREVIEW_QML_DIRECTORY) + "/" + name, qmlDirectory.filePath(name)));
        QFile manifest(qmlDirectory.filePath("qmldir"));
        QVERIFY(manifest.open(QIODevice::WriteOnly));
        manifest.write("singleton Theme 1.0 Theme.qml\n"); manifest.close();

        // Real controller and presentation; no document or network request is
        // created. This component test does not certify rendering or live HTML
        // form retention; those require separate WebEngine integration checks.
        ApiClient api(QUrl("http://127.0.0.1"));
        PhoenixClient realtime;
        SessionController session(api, realtime);
        CacheStore cache(cacheDirectory.path());
        ArtifactService artifacts(api, session, cache);
        PreviewController preview(artifacts);
        preview.setVisible(true);
        preview.openFile({{"id", "invalid"}});
        const auto previousError = preview.error();
        QVERIFY(!previousError.isEmpty());
        const auto previousDocuments = preview.documents();

        QQmlEngine engine;
        QStringList warnings;
        connect(&engine, &QQmlEngine::warnings, this, [&](const QList<QQmlError>& errors) {
            for (const auto& error : errors) warnings.append(error.toString());
        });
        engine.rootContext()->setContextProperty("preview", &preview);
        QQmlComponent component(&engine, QUrl::fromLocalFile(qmlDirectory.filePath("PreviewPanel.qml")));
        std::unique_ptr<QObject> panel(component.create());
        QVERIFY2(panel, qPrintable(component.errorString()));
        auto* root = qobject_cast<QQuickItem*>(panel.get()); QVERIFY(root);
        QQuickWindow window;
        window.resize(1100, 720); root->setParentItem(window.contentItem()); root->setSize(QSizeF(1100, 720)); window.show();
        auto* button = panel->findChild<QQuickItem*>("showNativeFiles"); QVERIFY(button);
        QCOMPARE(button->property("text").toString(), QString("Show Files"));
        QSignalSpy navigation(panel.get(), SIGNAL(filesRequested())); QVERIFY(navigation.isValid());
        QSignalSpy clear(&preview, &PreviewController::clearViewsRequested);
        button->forceActiveFocus();
        QTRY_VERIFY(button->hasActiveFocus());
        QTest::keyClick(&window, Qt::Key_Space);
        QTRY_COMPARE(navigation.size(), 1);
        QCOMPARE(clear.size(), 0);
        QCOMPARE(preview.documents(), previousDocuments);
        QCOMPARE(preview.error(), previousError);
        QVERIFY(preview.visible()); // The shell handles hiding, without clearing.
        QVERIFY2(warnings.isEmpty(), qPrintable(warnings.join('\n')));
        root->setParentItem(nullptr);
    }
};

int main(int argc, char** argv) {
    qputenv("QT_QPA_PLATFORM", "offscreen");
    QQuickWindow::setGraphicsApi(QSGRendererInterface::Software);
    QtWebEngineQuick::initialize();
    PreviewController::registerScheme();
    QQuickStyle::setStyle("Basic");
    QGuiApplication app(argc, argv);
    PreviewNavigationTests tests;
    return QTest::qExec(&tests, argc, argv);
}
#include "navigation_tests.moc"
