#include <mokaid/preview/preview_controller.hpp>
#include <QFile>
#include <QBuffer>
#include <QJsonDocument>
#include <QDataStream>
#include <QPainter>
#include <QPdfWriter>
#include <QTcpSocket>
#include <QFontDatabase>
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
#ifndef Q_MOC_RUN
namespace {
QQuickItem* visualItem(QQuickItem* root, const QString& name) {
    if (root->objectName() == name) return root;
    for (auto* child : root->childItems()) if (auto* found = visualItem(child, name)) return found;
    return nullptr;
}
class PreviewCredentials final : public CredentialStorage {
public:
    std::optional<QByteArray> read(const QString&) const override { return QByteArray("fixture-refresh"); }
    bool write(const QString&, const QByteArray&) const override { return true; }
    bool erase(const QString&) const override { return true; }
};
class PreviewFixtureApi final : public QObject {
public:
    QTcpServer server;
    QHash<QString, QByteArray> files;
    QStringList rawRequests;
    PreviewFixtureApi() {
        if (!server.listen(QHostAddress::LocalHost, 0)) qFatal("Preview integration test needs a temporary loopback port");
        connect(&server, &QTcpServer::newConnection, this, [this] {
            while (server.hasPendingConnections()) {
                auto* socket = server.nextPendingConnection();
                connect(socket, &QTcpSocket::disconnected, socket, &QObject::deleteLater);
                connect(socket, &QTcpSocket::readyRead, this, [this, socket] {
                    const auto bytes = socket->property("request").toByteArray() + socket->readAll();
                    socket->setProperty("request", bytes);
                    const auto end = bytes.indexOf("\r\n\r\n");
                    if (end < 0 || socket->property("handled").toBool()) return;
                    qsizetype length = 0;
                    for (const auto& line : bytes.left(end).split('\n'))
                        if (line.toLower().startsWith("content-length:")) length = line.mid(15).trimmed().toLongLong();
                    if (bytes.size() < end + 4 + length) return;
                    socket->setProperty("handled", true);
                    const auto path = QString::fromUtf8(bytes.split(' ').value(1));
                    QByteArray body, mime = "application/json";
                    int status = 200;
                    if (path == "/api/desktop/auth/token") body = R"({"data":{"access_token":"fixture-access","refresh_token":"fixture-refresh-next","token_type":"Bearer","expires_in":600,"user":{"id":"preview-user"}}})";
                    else if (path == "/api/me") body = R"({"user":{"id":"preview-user"},"workspaces":[{"id":"preview-workspace","name":"Preview fixture"}]})";
                    else if (path.endsWith("/raw")) {
                        rawRequests.append(path);
                        if (!bytes.contains("Authorization: Bearer fixture-access") || !files.contains(path)) status = 403;
                        else { body = files.value(path); mime = "application/octet-stream"; }
                    } else status = 404;
                    socket->write("HTTP/1.1 " + QByteArray::number(status) + " Response\r\nConnection: close\r\nContent-Type: " + mime + "\r\nContent-Length: " + QByteArray::number(body.size()) + "\r\n\r\n" + body);
                    socket->disconnectFromHost();
                });
            }
        });
    }
    QUrl origin() const { return QUrl(QString("http://127.0.0.1:%1").arg(server.serverPort())); }
};
}
#endif


class PreviewNavigationTests final : public QObject {
    Q_OBJECT
private slots:
    void galleryAndFormatAwareViewerUseAuthenticatedArtifacts();
    void filesButtonRequestsNativeNavigationWithoutEvictingPreviewState() {
        QTemporaryDir qmlDirectory, cacheDirectory;
        QVERIFY(qmlDirectory.isValid()); QVERIFY(cacheDirectory.isValid());
        QFontDatabase::addApplicationFont(QStringLiteral(MOKAID_PREVIEW_QML_DIRECTORY) + "/../assets/fonts/Manrope.ttf");
        for (const auto* name : {"PreviewPanel.qml", "DeliveryView.qml", "Theme.qml", "MokaidLabel.qml", "MokaidButton.qml", "MokaidIcon.qml", "MokaidMenu.qml"})
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
        // The confirmation dialogs must also measure correctly when their title
        // and explanatory text wrap, and Cancel must retain the deliverable.
        root->setWidth(400);
        for (const auto* name : {"replacePreviewDialog", "reloadPreviewDialog"}) {
            auto* dialog = panel->findChild<QObject*>(name); QVERIFY(dialog);
            QSignalSpy rejected(dialog, SIGNAL(rejected())); QVERIFY(rejected.isValid());
            QVERIFY(QMetaObject::invokeMethod(dialog, "open"));
            QTRY_VERIFY(dialog->property("visible").toBool());
            QVERIFY(dialog->property("height").toReal() > 100);
            QVERIFY(dialog->property("height").toReal() < window.height());
            QVERIFY(QMetaObject::invokeMethod(dialog, "reject"));
            QTRY_COMPARE(rejected.size(), 1);
            QTRY_VERIFY(!dialog->property("visible").toBool());
        }
        QCOMPARE(preview.documents(), previousDocuments);
        QCOMPARE(clear.size(), 0);
        QVERIFY2(warnings.isEmpty(), qPrintable(warnings.join('\n')));
        root->setParentItem(nullptr);
    }
};

void PreviewNavigationTests::galleryAndFormatAwareViewerUseAuthenticatedArtifacts() {
        QTemporaryDir staging, cacheDirectory, preferences;
        QVERIFY(staging.isValid()); QVERIFY(cacheDirectory.isValid()); QVERIFY(preferences.isValid());
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, preferences.path());
        const QString source = QStringLiteral(MOKAID_PREVIEW_QML_DIRECTORY);
        for (const auto* name : {"PreviewPanel.qml", "DeliveryView.qml", "DeliveryGallery.qml", "DeliveryCard.qml", "Theme.qml", "MokaidLabel.qml", "MokaidButton.qml", "MokaidIcon.qml", "MokaidMenu.qml"})
            QVERIFY(QFile::copy(source + "/" + name, staging.filePath(name)));
        QFile qmldir(staging.filePath("qmldir")); QVERIFY(qmldir.open(QIODevice::WriteOnly)); qmldir.write("singleton Theme 1.0 Theme.qml\n"); qmldir.close();
        QFontDatabase::addApplicationFont(source + "/../assets/fonts/Manrope.ttf");
        PreviewFixtureApi remote;
        const QString firstId = "aaaaaaaa-0000-4000-8000-000000000001", secondId = "aaaaaaaa-0000-4000-8000-000000000002", pdfId = "aaaaaaaa-0000-4000-8000-000000000003", textId = "aaaaaaaa-0000-4000-8000-000000000004";
        QVariantList files;
        for (const auto& entry : {QPair{firstId, QString("brand-orb.png")}, QPair{secondId, QString("portrait-design.png")}}) {
            QFile image(source + "/../assets/" + entry.second); QVERIFY(image.open(QIODevice::ReadOnly)); const auto bytes = image.readAll();
            remote.files.insert("/api/drive/" + entry.first + "/raw", bytes);
            files.append(QVariantMap{{"id", entry.first}, {"name", entry.second == "brand-orb.png" ? "Workforce · visual concept.png" : "Creative team · portrait.png"}, {"mime_type", "image/png"}, {"size_bytes", bytes.size()}});
        }
        QByteArray pdfBytes;
        {
            QBuffer buffer(&pdfBytes); QVERIFY(buffer.open(QIODevice::WriteOnly)); QPdfWriter writer(&buffer); writer.setResolution(96);
            QPainter painter(&writer); painter.setPen(QColor("#27233d")); painter.setFont(QFont("Manrope", 28)); painter.drawText(QPoint(64, 100), "Your creative direction");
            painter.setFont(QFont("Manrope", 13)); painter.drawText(QPoint(64, 152), "Preview test fixture · a real PDF document");
            painter.fillRect(QRect(64, 200, 420, 130), QColor("#c17436")); painter.end();
        }
        remote.files.insert("/api/drive/" + pdfId + "/raw", pdfBytes);
        files.append(QVariantMap{{"id", pdfId}, {"name", "Creative direction.pdf"}, {"mime_type", "application/pdf"}, {"size_bytes", pdfBytes.size()}});
        remote.files.insert("/api/drive/" + textId + "/raw", QByteArray("# Delivery notes\n\nA clean preview keeps the result at the center.\n\n- Two visual concepts\n- One creative brief\n"));
        files.append(QVariantMap{{"id", textId}, {"name", "Delivery notes.md"}, {"mime_type", "text/markdown"}});
        PreviewCredentials credentials;
        ApiClient api(remote.origin()); PhoenixClient realtime;
        SessionController session(api, realtime, nullptr, QUrl("https://mokaid.test"), &credentials);
        CacheStore cache(cacheDirectory.path()); ArtifactService artifacts(api, session, cache); PreviewController preview(artifacts);
        connect(&session, &SessionController::workspaceChanged, &preview, &PreviewController::clear);
        session.restore(); QTRY_VERIFY(session.authenticated()); QTRY_VERIFY(!session.busy());
        session.selectWorkspace("preview-workspace"); QTRY_COMPARE(session.workspaceId(), QString("preview-workspace"));
        QQmlEngine engine; QStringList warnings;
        connect(&engine, &QQmlEngine::warnings, this, [&](const QList<QQmlError>& errors) { for (const auto& error : errors) warnings.append(error.toString()); });
        engine.rootContext()->setContextProperty("preview", &preview); engine.rootContext()->setContextProperty("fixtureFiles", files);
        QQmlComponent component(&engine);
        component.setData(R"(
import QtQuick
import QtQuick.Controls
Rectangle {
    id: fixture
    width: 1000; height: 760; color: "#0b0b10"
    property int mediaReadyState: 0
    property bool mediaProbePending: false
    function findBrowser(item) {
        if (!item) return null
        if (typeof item.runJavaScript === "function") return item
        for (const child of item.children || []) {
            const found = findBrowser(child)
            if (found) return found
        }
        return null
    }
    function probeAudio() {
        const browser = findBrowser(viewer.activeView)
        if (!browser || mediaProbePending) return
        mediaProbePending = true
        browser.runJavaScript("document.querySelector('audio') ? document.querySelector('audio').readyState : 0", function(value) {
            fixture.mediaReadyState = value || 0
            fixture.mediaProbePending = false
        })
    }
    Column {
        anchors.centerIn: parent; width: Math.min(620, parent.width - 64); spacing: 20; visible: !preview.visible
        MokaidLabel { text: "Your results are ready"; font.pixelSize: 26; font.weight: Font.DemiBold }
        MokaidLabel { text: "Two visual directions and the supporting documents."; color: Theme.secondary }
        DeliveryGallery { width: parent.width; files: fixtureFiles; showHeading: false }
    }
    PreviewPanel { id: viewer; objectName: "previewPanel"; anchors.fill: parent; anchors.bottomMargin: 22; visible: preview.visible }
    MokaidLabel { anchors.bottom: parent.bottom; anchors.horizontalCenter: parent.horizontalCenter; text: "INTERFACE TEST · SAMPLE DELIVERABLES"; color: Theme.muted; font.pixelSize: 10 }
})", QUrl::fromLocalFile(staging.filePath("GalleryFixture.qml")));
        std::unique_ptr<QObject> root(component.create()); QVERIFY2(root, qPrintable(component.errorString()));
        auto* item = qobject_cast<QQuickItem*>(root.get()); QVERIFY(item);
        QQuickWindow window; window.resize(1000, 760); item->setParentItem(window.contentItem()); window.show();
        QTRY_VERIFY(!preview.thumbnailUrl(files.first().toMap()).isEmpty());
        QTRY_VERIFY(!preview.thumbnailUrl(files[1].toMap()).isEmpty());
        const auto output = qEnvironmentVariable("MOKAID_DELIVERABLE_CAPTURE_DIR");
        auto capture = [&](const QString& name) { if (!output.isEmpty()) { QDir().mkpath(output); QTest::qWait(160); QVERIFY(window.grabWindow().save(output + "/" + name + ".png")); } };
        capture("gallery");
        auto* card = visualItem(item, "deliveryCard_" + firstId); QVERIFY(card);
        card->forceActiveFocus(); QTest::keyClick(&window, Qt::Key_Space);
        QTRY_VERIFY(preview.visible()); QTRY_VERIFY(!preview.loading()); QTRY_VERIFY(preview.documents()[preview.activeIndex()].value<PreviewDocument*>());
        QCOMPARE(preview.collectionCount(), 4);
        auto* document = preview.documents()[preview.activeIndex()].value<PreviewDocument*>(); QCOMPARE(document->kind(), QString("image"));
        auto* picture = root->findChild<QQuickItem*>("deliverableImage"); QVERIFY(picture); QTRY_COMPARE(picture->property("status").toInt(), 1);
        capture("image-viewer");
        auto* previewActions = root->findChild<QObject*>("previewActionsButton"); QVERIFY(previewActions);
        auto* previewMenu = root->findChild<QObject*>("previewActionsMenu"); QVERIFY(previewMenu);
        QVERIFY(QMetaObject::invokeMethod(previewActions, "clicked"));
        QTRY_VERIFY(previewMenu->property("visible").toBool());
        QVERIFY(previewMenu->property("width").toReal() >= 224);
        QTest::keyClick(&window, Qt::Key_Escape);
        QTRY_VERIFY(!previewMenu->property("visible").toBool());
        QVERIFY(preview.visible());
        QSignalSpy downloads(&preview, &PreviewController::downloadRequested); preview.downloadCurrent(); QCOMPARE(downloads.size(), 1);
        QCOMPARE(downloads.first().first().toMap().value("id").toString(), firstId);
        auto* next = root->findChild<QObject*>("nextDeliverable"); QVERIFY(next); QVERIFY(QMetaObject::invokeMethod(next, "clicked"));
        QTRY_COMPARE(preview.collectionIndex(), 1); QTRY_VERIFY(!preview.loading());
        QTRY_COMPARE(preview.documents()[preview.activeIndex()].value<PreviewDocument*>()->file().value("id").toString(), secondId);
        window.resize(520, 700); item->setSize(QSizeF(520, 700)); capture("image-viewer-compact");
        QTest::keyClick(&window, Qt::Key_Escape); QTRY_VERIFY(!preview.visible());
        window.resize(1000, 760); item->setSize(QSizeF(1000, 760));
        preview.openCollection(files, 2);
        QTRY_VERIFY(!preview.loading()); QTRY_COMPARE(preview.documents()[preview.activeIndex()].value<PreviewDocument*>()->kind(), QString("pdf"));
        // Certify actual PDF page pixels, not merely successful wrapper loading.
        const auto pdfRendered = [&] {
            const auto pixels = window.grabWindow().convertToFormat(QImage::Format_RGB32);
            int orange = 0;
            for (int y = 90; y < pixels.height() - 100; y += 3)
                for (int x = 0; x < pixels.width(); x += 3) {
                    const auto color = pixels.pixelColor(x, y);
                    if (qAbs(color.red() - 193) < 8 && qAbs(color.green() - 116) < 8 && qAbs(color.blue() - 54) < 8) ++orange;
                }
            return orange > 100;
        };
        QTRY_VERIFY_WITH_TIMEOUT(pdfRendered(), 10000); capture("pdf-viewer");
        preview.openCollection(files, 3);
        QTRY_VERIFY(!preview.loading()); QTRY_COMPARE(preview.documents()[preview.activeIndex()].value<PreviewDocument*>()->kind(), QString("text"));
        QTest::qWait(700); capture("text-viewer");
        const auto textSource = preview.documents()[preview.activeIndex()].value<PreviewDocument*>()->localSource().toLocalFile();
        const auto thumbnailSource = QUrl(preview.thumbnailUrl(files.first().toMap())).toLocalFile();
        QVERIFY(QFile::exists(textSource)); QVERIFY(QFile::exists(thumbnailSource));

        // A failed attempt must retain its own recovery target, independently of
        // the previous successful document that remains on screen.
        const auto secondPath = "/api/drive/" + secondId + "/raw";
        const auto secondBytes = remote.files.take(secondPath);
        preview.openFile(files[1].toMap()); QTRY_VERIFY(!preview.loading());
        QTRY_COMPARE(preview.failedFile().value("id").toString(), secondId);
        QCOMPARE(preview.documents()[preview.activeIndex()].value<PreviewDocument*>()->file().value("id").toString(), textId);
        preview.downloadFailed(); QCOMPARE(downloads.last().first().toMap().value("id").toString(), secondId);
        remote.files.insert(secondPath, secondBytes); preview.retryFailed();
        QTRY_COMPARE(preview.documents()[preview.activeIndex()].value<PreviewDocument*>()->file().value("id").toString(), secondId);
        QVERIFY(preview.failedFile().isEmpty());
        const int secondSlot = preview.activeIndex();
        preview.openFile(files.first().toMap());
        QTRY_COMPARE(preview.documents()[preview.activeIndex()].value<PreviewDocument*>()->file().value("id").toString(), firstId);
        preview.activate(secondSlot); QCOMPARE(preview.collectionCount(), 1);
        preview.downloadCurrent(); QCOMPARE(downloads.last().first().toMap().value("id").toString(), secondId);
        auto tooLarge = files[2].toMap(); tooLarge.insert("size_bytes", 33 * 1024 * 1024);
        const auto requestCount = remote.rawRequests.size(); const auto downloadCount = downloads.size();
        preview.openFile(tooLarge); QVERIFY(preview.error().contains("32 MiB"));
        preview.downloadFailed(); QCOMPARE(downloads.size(), downloadCount); QCOMPARE(remote.rawRequests.size(), requestCount);

        // Verify the media element decodes actual PCM audio through the same
        // isolated scheme used in the shipped player, without autoplay/sound.
        QByteArray wave; QDataStream stream(&wave, QIODevice::WriteOnly); stream.setByteOrder(QDataStream::LittleEndian);
        stream.writeRawData("RIFF", 4); stream << quint32(16036); stream.writeRawData("WAVEfmt ", 8);
        stream << quint32(16) << quint16(1) << quint16(1) << quint32(8000) << quint32(16000) << quint16(2) << quint16(16);
        stream.writeRawData("data", 4); stream << quint32(16000); wave.append(QByteArray(16000, '\0'));
        const QString audioId = "aaaaaaaa-0000-4000-8000-000000000005";
        remote.files.insert("/api/drive/" + audioId + "/raw", wave);
        preview.openFile({{"id", audioId}, {"name", "Voice note.wav"}, {"mime_type", "audio/wav"}});
        QTRY_COMPARE(preview.documents()[preview.activeIndex()].value<PreviewDocument*>()->kind(), QString("audio"));
        QTRY_VERIFY_WITH_TIMEOUT(([&] {
            if (root->property("mediaReadyState").toInt() >= 1) return true;
            QMetaObject::invokeMethod(root.get(), "probeAudio"); return false;
        })(), 10000);
        QVERIFY2(warnings.isEmpty(), qPrintable(warnings.join('\n')));
        preview.clear(); QTRY_VERIFY(preview.documents()[0].value<PreviewDocument*>() == nullptr); QCOMPARE(preview.collectionCount(), 0);
        QVERIFY(!QFile::exists(textSource)); QVERIFY(!QFile::exists(thumbnailSource));
        QVERIFY(preview.thumbnailUrl(files.first().toMap()).isEmpty());
        item->setParentItem(nullptr);
    }

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
