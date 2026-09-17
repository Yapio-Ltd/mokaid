#include <mokaid/application/mission_controller.hpp>
#include <mokaid/presentation/project_runtime.hpp>
#include <QFile>
#include <QDragEnterEvent>
#include <QDropEvent>
#include <QMimeData>
#include <QFontDatabase>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQmlPropertyMap>
#include <QQuickItem>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QtTest>

using namespace mokaid::desktop;
class MissionQmlTests final : public QObject {
    Q_OBJECT
private slots:
    void localProjectSheetLoadsWithoutStartingCode() {
        QTemporaryDir staging, project; QVERIFY(staging.isValid()); QVERIFY(project.isValid());
        const QString source = QStringLiteral(MOKAID_MISSION_QML_DIRECTORY);
        for (const auto* name : {"ProjectPanel.qml", "MokaidDialog.qml", "MokaidIcon.qml", "MokaidLabel.qml", "MokaidButton.qml", "MokaidTextArea.qml", "Theme.qml"})
            QVERIFY(QFile::copy(source + "/" + name, staging.path() + "/" + name));
        QFile qmldir(staging.path() + "/qmldir"); QVERIFY(qmldir.open(QIODevice::WriteOnly)); qmldir.write("singleton Theme 1.0 Theme.qml\n"); qmldir.close();
        QFile package(project.path() + "/package.json"); QVERIFY(package.open(QIODevice::WriteOnly)); package.write(R"({"name":"Synthetic project fixture","scripts":{"dev":"vite"},"devDependencies":{"vite":"*"}})"); package.close();
        ProjectRuntime runtime; runtime.inspect(QUrl::fromLocalFile(project.path())); QCOMPARE(runtime.state(), QString("ready"));
        QQmlEngine engine; QStringList warnings;
        connect(&engine, &QQmlEngine::warnings, this, [&](const QList<QQmlError>& errors) { for (const auto& error : errors) warnings.append(error.toString()); });
        engine.rootContext()->setContextProperty("projectRuntime", &runtime);
        QQmlComponent component(&engine); component.setData("import QtQuick\nRectangle { width: 1000; height: 750; color: '#0b0b10'; ProjectPanel { objectName: 'projectPanel' } }", QUrl::fromLocalFile(staging.path() + "/ProjectFixture.qml"));
        std::unique_ptr<QObject> root(component.create()); QVERIFY2(root, qPrintable(component.errorString()));
        auto* item = qobject_cast<QQuickItem*>(root.get()); QVERIFY(item); QQuickWindow window; window.resize(1000, 750); item->setParentItem(window.contentItem()); window.show();
        auto* panel = root->findChild<QObject*>("projectPanel"); QVERIFY(panel); QVERIFY(QMetaObject::invokeMethod(panel, "open")); QTest::qWait(120);
        const auto output = qEnvironmentVariable("MOKAID_MISSION_CAPTURE_DIR"); if (!output.isEmpty()) { QDir().mkpath(output); QVERIFY(window.grabWindow().save(output + "/project-preview.png")); }
        QCOMPARE(runtime.state(), QString("ready")); QVERIFY(!runtime.busy()); QVERIFY(runtime.url().isEmpty());
        QVERIFY2(warnings.isEmpty(), qPrintable(warnings.join('\n'))); item->setParentItem(nullptr);
    }
    void filesReviewCustomAgentAndLaunch() {
        QTemporaryDir staging, cacheDirectory, files;
        QVERIFY(staging.isValid()); QVERIFY(cacheDirectory.isValid()); QVERIFY(files.isValid());
        const QString source = QStringLiteral(MOKAID_MISSION_QML_DIRECTORY);
        for (const auto* name : {"MissionPanel.qml", "MokaidIcon.qml", "MokaidIconButton.qml", "MokaidLabel.qml", "MokaidButton.qml", "MokaidTextField.qml", "MokaidTextArea.qml", "Theme.qml"})
            QVERIFY(QFile::copy(source + "/" + name, staging.path() + "/" + name));
        QFile qmldir(staging.path() + "/qmldir"); QVERIFY(qmldir.open(QIODevice::WriteOnly)); qmldir.write("singleton Theme 1.0 Theme.qml\n"); qmldir.close();
        QFontDatabase::addApplicationFont(source + "/../assets/fonts/Manrope.ttf");
        QFile attachment(files.path() + "/campaign.custom"); QVERIFY(attachment.open(QIODevice::WriteOnly)); attachment.write("synthetic attachment"); attachment.close();
        QTcpServer server; QVERIFY(server.listen(QHostAddress::LocalHost, 0));
        QStringList requests; QJsonObject confirmed;
        const QJsonObject agent{{"id", "agent-one"}, {"display_name", "Alex · test agent"}, {"role_title", "Research analyst"}, {"kind", "ai"}, {"status", "idle"}};
        connect(&server, &QTcpServer::newConnection, this, [&] {
            while (server.hasPendingConnections()) {
                auto* socket = server.nextPendingConnection(); connect(socket, &QTcpSocket::disconnected, socket, &QObject::deleteLater);
                connect(socket, &QTcpSocket::readyRead, this, [&, socket] {
                    auto bytes = socket->property("request").toByteArray() + socket->readAll(); socket->setProperty("request", bytes);
                    const auto split = bytes.indexOf("\r\n\r\n"); if (split < 0 || socket->property("handled").toBool()) return;
                    qsizetype length = 0;
                    for (auto line : bytes.left(split).split('\n')) if (line.toLower().startsWith("content-length:")) length = line.mid(15).trimmed().toLongLong();
                    if (bytes.size() < split + 4 + length) return;
                    socket->setProperty("handled", true);
                    const auto path = QString::fromUtf8(bytes.split(' ').value(1)); requests.append(path);
                    QJsonObject response{{"data", QJsonArray{}}};
                    if (path == "/api/agents") response = {{"data", QJsonArray{agent}}};
                    if (path == "/api/drive/upload") response = {{"data", QJsonObject{{"id", "file-one"}, {"name", "campaign.custom"}}}};
                    if (path == "/api/dispatch/analyze") response = {{"data", QJsonObject{
                        {"task", QJsonObject{{"title", "Compare the campaign proposals"}, {"description", "Analyze the attached proposals and deliver a concise comparison with a recommendation."}, {"priority", "medium"}}},
                        {"recommendation", QJsonObject{{"mode", "existing_agent"}, {"agent_id", "agent-one"}, {"confidence", 94}, {"reason", "Alex’s research skills fit the comparison and synthesis requested."},
                            {"custom_agent", QJsonObject{{"display_name", "Campaign specialist"}, {"role_title", "Campaign research"}, {"archetype_key", "research"}, {"skills", QJsonArray{QJsonObject{{"name", "Research"}, {"level", 3}}}}}}}}, {"mcp_suggestions", QJsonArray{}}}}};
                    if (path == "/api/dispatch/confirm") {
                        confirmed = QJsonDocument::fromJson(bytes.mid(split + 4, length)).object();
                        response = {{"data", QJsonObject{{"task", QJsonObject{{"id", "task-one"}, {"title", "Compare the campaign proposals"}}}, {"agent", agent}, {"run_id", "run-one"}}}};
                    }
                    const auto body = QJsonDocument(response).toJson(QJsonDocument::Compact);
                    socket->write("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: " + QByteArray::number(body.size()) + "\r\n\r\n" + body); socket->disconnectFromHost();
                });
            }
        });
        ApiClient api(QUrl(QString("http://127.0.0.1:%1").arg(server.serverPort()))); api.setSession("synthetic", "user-one", false); api.setWorkspace("workspace-one");
        PhoenixClient realtime; SessionController session(api, realtime); CacheStore cache(cacheDirectory.path()); ActivityController activity(api, session, realtime, cache);
        MissionController missions(api, session, realtime, activity);
        auto uiSession = std::unique_ptr<QQmlPropertyMap>(QQmlPropertyMap::create()); uiSession->insert("online", true);
        QQmlEngine engine; QStringList warnings;
        connect(&engine, &QQmlEngine::warnings, this, [&](const QList<QQmlError>& errors) { for (const auto& error : errors) warnings.append(error.toString()); });
        engine.rootContext()->setContextProperty("missions", &missions); engine.rootContext()->setContextProperty("session", uiSession.get());
        QQmlComponent component(&engine);
        component.setData("import QtQuick\nRectangle { width: 720; height: 800; color: '#0b0b10'; MissionPanel { objectName: 'missionPanel'; anchors.fill: parent; anchors.bottomMargin: 24 } Text { anchors.bottom: parent.bottom; anchors.horizontalCenter: parent.horizontalCenter; text: 'INTERFACE TEST · SYNTHETIC DATA'; color: '#b3bcde'; font.pixelSize: 10 } }", QUrl::fromLocalFile(staging.path() + "/MissionFixture.qml"));
        std::unique_ptr<QObject> root(component.create()); QVERIFY2(root, qPrintable(component.errorString()));
        auto* item = qobject_cast<QQuickItem*>(root.get()); QVERIFY(item);
        QQuickWindow window; window.resize(720, 800); item->setParentItem(window.contentItem()); window.show();
        missions.begin(); QTRY_VERIFY(requests.contains("/api/agents"));
        auto* instruction = root->findChild<QQuickItem*>("missionInstruction"); QVERIFY(instruction);
        instruction->forceActiveFocus(); for (char key : QByteArray("Compare these proposals and recommend the best fit.")) QTest::keyClick(&window, key);
        QTRY_VERIFY(missions.instruction().contains("Compare these proposals"));
        QMimeData dropData; dropData.setUrls({QUrl::fromLocalFile(attachment.fileName())});
        QDragEnterEvent enter(QPoint(160, 350), Qt::CopyAction, &dropData, Qt::LeftButton, Qt::NoModifier);
        QCoreApplication::sendEvent(&window, &enter); QVERIFY(enter.isAccepted());
        QDropEvent drop(QPointF(160, 350), Qt::CopyAction, &dropData, Qt::LeftButton, Qt::NoModifier);
        QCoreApplication::sendEvent(&window, &drop); QVERIFY(drop.isAccepted()); QCOMPARE(missions.attachments().size(), 1);
        auto* next = root->findChild<QObject*>("missionContinue"); QVERIFY(next); QVERIFY(next->property("enabled").toBool());
        const auto output = qEnvironmentVariable("MOKAID_MISSION_CAPTURE_DIR");
        auto capture = [&](const QString& name) { if (!output.isEmpty()) { QDir().mkpath(output); QTest::qWait(120); QVERIFY(window.grabWindow().save(output + "/" + name + ".png")); } };
        capture("mission-brief");
        QVERIFY(QMetaObject::invokeMethod(next, "clicked")); QTRY_COMPARE(missions.step(), QString("recommend"));
        QCOMPARE(missions.attachments().front().toMap().value("status").toString(), QString("ready")); QVERIFY(missions.canLaunch());
        capture("mission-match");
        auto* specialist = root->findChild<QObject*>("missionNewAgent"); QVERIFY(specialist); QVERIFY(specialist->property("visible").toBool());
        QVERIFY(QMetaObject::invokeMethod(specialist, "clicked")); QVERIFY(missions.customSelected());
        auto* name = root->findChild<QQuickItem*>("missionAgentName"); QVERIFY(name); name->forceActiveFocus();
        QMetaObject::invokeMethod(name, "selectAll"); for (char key : QByteArray("Morgan")) QTest::keyClick(&window, key);
        QTRY_COMPARE(missions.customAgent().value("display_name").toString(), QString("Morgan"));
        capture("mission-new-agent");
        window.resize(690, 550); item->setSize(QSizeF(690, 550)); capture("mission-compact");
        uiSession->insert("online", false); QTRY_VERIFY(!next->property("enabled").toBool()); uiSession->insert("online", true);
        QVERIFY(QMetaObject::invokeMethod(next, "clicked")); QTRY_COMPARE(missions.step(), QString("done"));
        QCOMPARE(confirmed.value("drive_item_ids").toArray(), QJsonArray{"file-one"}); QCOMPARE(confirmed.value("custom_agent").toObject().value("display_name").toString(), QString("Morgan"));
        QVERIFY(!confirmed.value("client_request_id").toString().isEmpty());
        window.resize(720, 800); item->setSize(QSizeF(720, 800)); capture("mission-started");
        QVERIFY2(warnings.isEmpty(), qPrintable(warnings.join('\n'))); item->setParentItem(nullptr);
    }
};
int main(int argc, char** argv) { QGuiApplication app(argc, argv); QQuickStyle::setStyle("Basic"); MissionQmlTests tests; return QTest::qExec(&tests, argc, argv); }
#include "mission_qml_tests.moc"
