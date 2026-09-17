#include <mokaid/application/mission_controller.hpp>
#include <QFile>
#include <QJsonDocument>
#include <QPointer>
#include <QSettings>
#include <QSignalSpy>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QtTest>
#include <algorithm>

using namespace mokaid::desktop;
namespace {
struct Request { QString path; QByteArray headers, raw; QJsonObject body; };
QJsonObject recommendation(bool custom = false) {
    const QJsonObject specialist{{"display_name", "Researcher"}, {"role_title", "Research specialist"},
        {"skills", QJsonArray{QJsonObject{{"name", "Research"}, {"level", 4}}}}};
    const QJsonObject routing{{"mode", custom ? "custom_agent" : "existing_agent"},
        {"agent_id", custom ? QJsonValue() : QJsonValue("agent-a")}, {"confidence", 88},
        {"reason", "Relevant experience"}, {"alternatives", QJsonArray{}}, {"custom_agent", specialist}};
    return {{"task", QJsonObject{{"title", "Review the brief"}, {"description", "Produce a checked summary"}, {"priority", "medium"}}},
        {"recommendation", routing}, {"mcp_suggestions", QJsonArray{
            QJsonObject{{"installation_id", "tool-a"}, {"server_name", "Documents"}, {"status", "needs_grant"}},
            QJsonObject{{"installation_id", "tool-b"}, {"server_name", "Unconnected"}, {"status", "not_installed"}}}}};
}
class MissionApi final : public QObject {
public:
    QTcpServer server;
    QList<Request> requests;
    QJsonArray notifications;
    bool custom{};
    std::function<bool(QTcpSocket*, const Request&)> handler;
    MissionApi() {
        server.listen(QHostAddress::LocalHost, 0);
        connect(&server, &QTcpServer::newConnection, this, [this] {
            while (server.hasPendingConnections()) {
                auto* socket = server.nextPendingConnection();
                connect(socket, &QTcpSocket::disconnected, socket, &QObject::deleteLater);
                connect(socket, &QTcpSocket::readyRead, this, [this, socket] {
                    auto bytes = socket->property("request").toByteArray() + socket->readAll(); socket->setProperty("request", bytes);
                    const auto end = bytes.indexOf("\r\n\r\n");
                    if (end < 0 || socket->property("handled").toBool()) return;
                    qsizetype length = 0;
                    for (const auto& line : bytes.left(end).split('\n'))
                        if (line.toLower().startsWith("content-length:")) length = line.mid(15).trimmed().toLongLong();
                    if (bytes.size() < end + 4 + length) return;
                    socket->setProperty("handled", true);
                    const auto line = bytes.left(bytes.indexOf("\r\n")).split(' ');
                    Request request{QString::fromUtf8(line.value(1)), bytes.left(end), bytes.mid(end + 4, length), {}};
                    request.body = QJsonDocument::fromJson(request.raw).object(); requests.append(request);
                    if (handler && handler(socket, request)) return;
                    if (request.path == "/api/agents") reply(socket, {{"data", QJsonArray{
                        QJsonObject{{"id", "agent-a"}, {"display_name", "Alice"}, {"role_title", "Analyst"}},
                        QJsonObject{{"id", "agent-b"}, {"display_name", "Bob"}, {"role_title", "Developer"}}}}});
                    else if (request.path == "/api/notifications") reply(socket, {{"data", notifications}});
                    else if (request.path == "/api/drive/upload") reply(socket, {{"data", QJsonObject{
                        {"id", QString("file-%1").arg(count("/api/drive/upload"))}, {"name", "attachment.unknown"}}}});
                    else if (request.path == "/api/dispatch/analyze") reply(socket, {{"data", recommendation(custom)}});
                    else if (request.path == "/api/dispatch/confirm") reply(socket, {{"data", QJsonObject{
                        {"task", QJsonObject{{"id", "task-a"}, {"title", "Review the brief"}}},
                        {"agent", QJsonObject{{"id", "agent-a"}, {"display_name", "Alice"}}}, {"run_id", "run-a"}}}}, 201);
                    else reply(socket, {{"data", QJsonArray{}}});
                });
            }
        });
    }
    QUrl origin() const { return QUrl(QString("http://127.0.0.1:%1").arg(server.serverPort())); }
    int count(const QString& path) const { return static_cast<int>(std::count_if(requests.cbegin(), requests.cend(), [&](const auto& r) { return r.path == path; })); }
    Request last(const QString& path) const {
        for (auto it = requests.crbegin(); it != requests.crend(); ++it) if (it->path == path) return *it;
        return {};
    }
    static void reply(QTcpSocket* socket, const QJsonObject& object, int status = 200) {
        const auto json = QJsonDocument(object).toJson(QJsonDocument::Compact);
        socket->write("HTTP/1.1 " + QByteArray::number(status) + " Response\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: " +
            QByteArray::number(json.size()) + "\r\n\r\n" + json); socket->disconnectFromHost();
    }
};
struct Fixture {
    MissionApi remote;
    QTemporaryDir directory;
    CacheStore cache{directory.path()};
    ApiClient api{remote.origin()};
    PhoenixClient realtime;
    SessionController session{api, realtime};
    ActivityController activity{api, session, realtime, cache};
    MissionController missions{api, session, realtime, activity};
    Fixture() { api.setSession("fixture-token", "alice", false); api.setWorkspace("workspace-a"); emit session.changed(); }
    QUrl file(const QString& name, const QByteArray& data = "opaque binary content") {
        const auto path = directory.filePath(name); QFile file(path);
        if (!file.open(QIODevice::WriteOnly) || file.write(data) != data.size()) qFatal("Could not prepare mission fixture file");
        file.close();
        return QUrl::fromLocalFile(path);
    }
};
QJsonObject notification(const QString& id, const QString& kind = "ai_run_completed") {
    return {{"id", id}, {"kind", kind}, {"title", "Ready for review"}, {"body", "The checked result is ready"},
        {"resource_type", "task"}, {"resource_id", "task-a"}, {"read_at", QJsonValue()},
        {"inserted_at", "2020-01-01T00:00:00Z"}};
}
}

class MissionTests final : public QObject {
    Q_OBJECT
    QTemporaryDir preferences_;
private slots:
    void initTestCase() {
        QCoreApplication::setOrganizationName("MokaidMissionTests");
        QCoreApplication::setOrganizationDomain("invalid.mokaid.tests");
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, preferences_.path());
    }
    void arbitraryFormatsAreStagedWithoutUploadAndDraftsAreRetained() {
        Fixture f; f.missions.begin("Inspect these materials");
        const auto unknown = f.file("content.unrecognized");
        f.missions.addFiles({unknown, unknown, QUrl("https://example.com/private")});
        QCOMPARE(f.missions.attachments().size(), 1);
        QCOMPARE(f.missions.attachments().first().toMap().value("status").toString(), QString("queued"));
        QCOMPARE(f.remote.count("/api/drive/upload"), 0);
        QVERIFY(!f.missions.error().isEmpty()); QVERIFY(f.missions.hasDraft());
        f.missions.close(); QVERIFY(!f.missions.opened()); f.missions.begin();
        QCOMPARE(f.missions.instruction(), QString("Inspect these materials")); QCOMPARE(f.missions.attachments().size(), 1);
        f.missions.addFiles({QUrl::fromLocalFile(f.directory.path())});
        QCOMPARE(f.missions.attachments().size(), 1);
        QFile large(f.directory.filePath("too-large.bin")); QVERIFY(large.open(QIODevice::WriteOnly));
        QVERIFY(large.resize(f.missions.maximumFileBytes() + 1)); large.close();
        f.missions.addFiles({QUrl::fromLocalFile(large.fileName())}); QCOMPARE(f.missions.attachments().size(), 1);
        f.api.setOnline(false); f.missions.analyze(); QVERIFY(!f.missions.busy()); QVERIFY(!f.missions.canLaunch());
        QCOMPARE(f.remote.count("/api/drive/upload"), 0);
    }
    void partialUploadRetryReusesSuccessfulFilesAndAuthenticatesMultipart() {
        Fixture f; bool failSecond = true;
        f.remote.handler = [&](QTcpSocket* socket, const Request& request) {
            if (request.path == "/api/drive/upload" && f.remote.count(request.path) == 2 && failSecond) {
                failSecond = false; MissionApi::reply(socket, {{"error", "Temporary upload error"}}, 503); return true;
            }
            return false;
        };
        f.missions.begin("Compare documents"); f.missions.addFiles({f.file("one.weird"), f.file("two.pdf")});
        f.missions.analyze(); QTRY_VERIFY(!f.missions.busy());
        QCOMPARE(f.missions.attachments().at(0).toMap().value("status").toString(), QString("ready"));
        QCOMPARE(f.missions.attachments().at(1).toMap().value("status").toString(), QString("error"));
        QCOMPARE(f.remote.count("/api/dispatch/analyze"), 0);
        f.missions.retryFile(f.missions.attachments().at(1).toMap().value("id").toString());
        QTRY_VERIFY(!f.missions.busy()); QCOMPARE(f.remote.count("/api/drive/upload"), 3);
        f.missions.analyze(); QTRY_COMPARE(f.missions.step(), QString("recommend"));
        const auto files = f.remote.last("/api/dispatch/analyze").body.value("files").toArray();
        QCOMPARE(files.size(), 2); QCOMPARE(files.at(0).toObject().value("drive_item_id").toString(), QString("file-1"));
        QCOMPARE(files.at(1).toObject().value("drive_item_id").toString(), QString("file-3"));
        const auto uploaded = f.remote.last("/api/drive/upload");
        QVERIFY(uploaded.headers.toLower().contains("authorization: bearer fixture-token"));
        QVERIFY(uploaded.headers.toLower().contains("x-workspace-id: workspace-a"));
        QVERIFY(uploaded.raw.contains("name=\"file\"")); QVERIFY(uploaded.raw.contains("opaque binary content"));
        f.missions.edit(); f.missions.setInstruction("Compare and summarize"); f.missions.analyze();
        QTRY_COMPARE(f.missions.step(), QString("recommend")); QCOMPARE(f.remote.count("/api/drive/upload"), 3);
    }
    void customAgentLaunchPreservesSkillsAndExplicitGrants() {
        Fixture f; f.remote.custom = true; QSignalSpy launched(&f.missions, &MissionController::launched);
        f.missions.begin("Research a subject"); f.missions.analyze();
        QTRY_COMPARE(f.missions.step(), QString("recommend")); QVERIFY(f.missions.customSelected());
        QCOMPARE(f.missions.grants().size(), 1); QVERIFY(!f.missions.grants().first().toMap().value("selected").toBool());
        f.missions.configureCustomAgent("Maya", "Research lead", "Always link primary sources");
        f.missions.setGrant("tool-a", true); f.missions.setGrant("tool-b", true);
        QVERIFY(f.missions.canLaunch()); f.missions.launch(); f.missions.launch();
        QTRY_COMPARE(f.missions.step(), QString("done")); QCOMPARE(launched.size(), 1); QCOMPARE(f.remote.count("/api/dispatch/confirm"), 1);
        const auto body = f.remote.last("/api/dispatch/confirm").body;
        QVERIFY(!body.contains("agent_id")); QVERIFY(body.value("start_now").toBool());
        QCOMPARE(body.value("custom_agent").toObject().value("display_name").toString(), QString("Maya"));
        QCOMPARE(body.value("custom_agent").toObject().value("skills").toArray().size(), 1);
        QCOMPARE(body.value("custom_agent").toObject().value("instructions").toString(), QString("Always link primary sources"));
        QCOMPARE(body.value("grant_installation_ids").toArray(), QJsonArray{"tool-a"});
        QVERIFY(!f.missions.hasDraft()); QVERIFY(!body.value("client_request_id").toString().isEmpty());
        f.missions.begin(); QCOMPARE(f.missions.step(), QString("describe")); QVERIFY(f.missions.instruction().isEmpty());
    }
    void retryUsesSameIdempotencyKeyAndProtectsUncertainPayload() {
        Fixture f; bool fail = true;
        f.remote.handler = [&](QTcpSocket* socket, const Request& request) {
            if (request.path == "/api/dispatch/confirm" && fail) {
                fail = false; MissionApi::reply(socket, {{"error", "Delivery interrupted"}}, 503); return true;
            } return false;
        };
        f.missions.begin("Summarize"); f.missions.analyze(); QTRY_VERIFY(f.missions.canLaunch());
        f.missions.launch(); QTRY_VERIFY(!f.missions.busy());
        const auto first = f.remote.last("/api/dispatch/confirm").body;
        QVERIFY(f.missions.launchUncertain()); f.missions.setInstruction("Different");
        f.missions.edit(); f.missions.selectAgent("agent-b");
        QCOMPARE(f.missions.instruction(), QString("Summarize")); QCOMPARE(f.missions.step(), QString("recommend"));
        f.missions.launch(); QTRY_COMPARE(f.missions.step(), QString("done"));
        QCOMPARE(f.remote.last("/api/dispatch/confirm").body, first);
    }
    void directAssignmentStillAnalyzesAndWarnsAboutMismatch() {
        Fixture f; f.missions.beginForAgent("agent-b", "Analyze the brief");
        QTRY_VERIFY(f.remote.count("/api/agents") > 0);
        f.missions.analyze(); QTRY_COMPARE(f.missions.step(), QString("recommend"));
        QCOMPARE(f.missions.selectedAgentId(), QString("agent-b")); QVERIFY(!f.missions.capabilityWarning().isEmpty());
        f.missions.launch(); QTRY_COMPARE(f.missions.step(), QString("done"));
        const auto body = f.remote.last("/api/dispatch/confirm").body;
        QCOMPARE(body.value("agent_id").toString(), QString("agent-b"));
        QVERIFY(body.value("capability_match").toObject().value("warning_shown").toBool());
    }
    void missingRunNeverClaimsThatTheAgentHasStarted() {
        Fixture f; QSignalSpy launched(&f.missions, &MissionController::launched);
        f.remote.handler = [](QTcpSocket* socket, const Request& request) {
            if (request.path != "/api/dispatch/confirm") return false;
            MissionApi::reply(socket, {{"data", QJsonObject{{"task", QJsonObject{{"id", "task-a"}}},
                {"agent", QJsonObject{{"id", "agent-a"}}}, {"run_id", QJsonValue()}}}}, 201); return true;
        };
        f.missions.begin("Summarize"); f.missions.analyze(); QTRY_VERIFY(f.missions.canLaunch());
        f.missions.launch(); QTRY_VERIFY(!f.missions.busy());
        QCOMPARE(launched.size(), 0); QCOMPARE(f.missions.step(), QString("recommend")); QVERIFY(f.missions.launchUncertain());
    }
    void changingWorkspaceCancelsDraftAndLateAnalysis() {
        Fixture f; QPointer<QTcpSocket> pending;
        f.remote.handler = [&](QTcpSocket* socket, const Request& request) {
            if (request.path == "/api/dispatch/analyze") { pending = socket; return true; } return false;
        };
        f.missions.begin("Private workspace A brief"); f.missions.analyze(); QTRY_VERIFY(pending);
        f.api.setWorkspace("workspace-b"); emit f.session.workspaceChanged();
        QVERIFY(!f.missions.opened()); QVERIFY(f.missions.instruction().isEmpty()); QVERIFY(!f.missions.busy());
        if (pending) MissionApi::reply(pending, {{"data", recommendation()}});
        QCoreApplication::processEvents(); QVERIFY(f.missions.analysis().isEmpty());
    }
    void generationChangeDuringLaunchRetriesTheOriginalRequest() {
        Fixture f; QPointer<QTcpSocket> pending; bool delay = true;
        f.remote.handler = [&](QTcpSocket* socket, const Request& request) {
            if (request.path == "/api/dispatch/confirm" && delay) { pending = socket; return true; } return false;
        };
        f.missions.begin("Summarize"); f.missions.analyze(); QTRY_VERIFY(f.missions.canLaunch());
        f.missions.launch(); QTRY_VERIFY(pending);
        const auto original = f.remote.last("/api/dispatch/confirm").body;
        f.api.cancelAll(); emit f.session.changed();
        QCOMPARE(f.missions.step(), QString("recommend")); QVERIFY(f.missions.launchUncertain());
        delay = false; f.missions.launch(); QTRY_COMPARE(f.missions.step(), QString("done"));
        QCOMPARE(f.remote.last("/api/dispatch/confirm").body, original);
    }
    void completionRequiresScopedNotificationAndDeduplicatesEvents() {
        Fixture f; QSignalSpy completed(&f.missions, &MissionController::completed);
        f.remote.notifications = {notification("historic")}; f.activity.refreshNotifications();
        QTRY_COMPARE(f.activity.notifications().size(), 1); QCOMPARE(completed.size(), 0);
        emit f.realtime.eventReceived("notifications:alice", "notification.created",
            {{"notification_id", "foreign"}, {"title", "Untrusted broadcast"}, {"kind", "ai_run_completed"}});
        QTest::qWait(140); QCOMPARE(completed.size(), 0);
        f.remote.notifications.append(notification("new-result"));
        emit f.realtime.eventReceived("notifications:alice", "notification.created", {{"notification_id", "new-result"}});
        QTRY_COMPARE(completed.size(), 1);
        QCOMPARE(completed.first().first().toMap().value("title").toString(), QString("Ready for review"));
        emit f.realtime.eventReceived("notifications:alice", "notification.created", {{"notification_id", "new-result"}});
        f.activity.refreshNotifications(); QTest::qWait(140); QCOMPARE(completed.size(), 1);
        f.remote.notifications.append(notification("approval", "approval_requested"));
        emit f.realtime.eventReceived("notifications:alice", "notification.created", {{"notification_id", "approval"}});
        QTRY_COMPARE(completed.size(), 2);
        f.remote.notifications.append(notification("needs-input", "ai_run_needs_input"));
        emit f.realtime.eventReceived("notifications:alice", "notification.created", {{"notification_id", "needs-input"}});
        QTRY_COMPARE(completed.size(), 3);
    }
};
QTEST_GUILESS_MAIN(MissionTests)
#include "mission_controller_tests.moc"
