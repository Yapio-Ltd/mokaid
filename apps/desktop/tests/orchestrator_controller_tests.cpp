#include <mokaid/application/orchestrator_controller.hpp>
#include <QJsonDocument>
#include <QPointer>
#include <QSignalSpy>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QtTest>

using namespace mokaid::desktop;
namespace {
struct Request { QString path; QByteArray headers; QJsonObject body; };
class Remote final : public QObject {
public:
    QTcpServer server;
    QList<Request> requests;
    bool failChat{}, holdChat{}, askInstead{};
    QPointer<QTcpSocket> held;
    Remote() {
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
                    Request request{QString::fromUtf8(bytes.left(bytes.indexOf("\r\n")).split(' ').value(1)), bytes.left(end),
                        QJsonDocument::fromJson(bytes.mid(end + 4, length)).object()};
                    requests.append(request);
                    if (request.path == "/api/orchestrator/chat") {
                        if (holdChat) { held = socket; return; }
                        if (failChat) { reply(socket, {{"error", "Model unavailable"}}, 503); return; }
                        if (askInstead) {
                            reply(socket, {{"data", QJsonObject{{"reply", "Je peux préparer une mission de recherche SEO. Veux-tu que je prépare cette mission d'audit SEO ?"}, {"language", "fr"}}}});
                            return;
                        }
                        reply(socket, {{"data", QJsonObject{{"reply", "Voici la mission à préparer."}, {"language", "fr"},
                            {"mission_instruction", "Étudier le marché et livrer un rapport sourcé."}, {"task_id", "foreign-task"}}}});
                    } else if (request.path == "/api/orchestrator/missions") {
                        const QJsonArray attachments{QJsonObject{{"id", "input-a"}, {"source", "input"}},
                            QJsonObject{{"id", "output-a"}, {"source", "output"}}};
                        const QJsonObject task{{"id", "task-a"}, {"title", "Research"}, {"status", "in_review"},
                            {"assigned_agent_name", "Mia"}, {"attachments", attachments}};
                        reply(socket, {{"data", QJsonArray{task}}});
                    } else reply(socket, {{"data", QJsonArray{}}});
                });
            }
        });
    }
    QUrl origin() const { return QUrl(QString("http://127.0.0.1:%1").arg(server.serverPort())); }
    int count(const QString& path) const { int n = 0; for (const auto& r : requests) if (r.path == path) ++n; return n; }
    Request last(const QString& path) const { for (auto i = requests.crbegin(); i != requests.crend(); ++i) if (i->path == path) return *i; return {}; }
    static void reply(QTcpSocket* socket, const QJsonObject& object, int status = 200) {
        const auto bytes = QJsonDocument(object).toJson(QJsonDocument::Compact);
        socket->write("HTTP/1.1 " + QByteArray::number(status) + " Response\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: "
            + QByteArray::number(bytes.size()) + "\r\n\r\n" + bytes); socket->disconnectFromHost();
    }
};
struct Fixture {
    Remote remote;
    QTemporaryDir directory;
    CacheStore cache{directory.path()};
    ApiClient api{remote.origin()};
    PhoenixClient realtime;
    SessionController session{api, realtime};
    ActivityController activity{api, session, realtime, cache};
    MissionController mission{api, session, realtime, activity};
    OrchestratorController controller{api, session, realtime, cache, mission};
    Fixture() { api.setSession("fixture-token", "user-a", false); api.setWorkspace("workspace-a"); emit session.changed(); }
};
}
class OrchestratorTests final : public QObject {
    Q_OBJECT
private slots:
    void replyCreatesProposalWithoutDispatchingAndSendsLanguage() {
        Fixture f; QSignalSpy spoken(&f.controller, &OrchestratorController::assistantReplied);
        f.controller.setDraft("Prépare une étude"); f.controller.sendMessage({}, "fr");
        QTRY_COMPARE(spoken.size(), 1); QVERIFY(!f.controller.busy()); QVERIFY(f.controller.draft().isEmpty());
        QCOMPARE(f.controller.messages().size(), 2);
        QCOMPARE(f.controller.messages().last().toMap().value("role").toString(), QString("assistant"));
        QVERIFY(f.controller.messages().last().toMap().value("task_id").toString().isEmpty());
        QVERIFY(!f.controller.pendingInstruction().isEmpty());
        const auto request = f.remote.last("/api/orchestrator/chat");
        QCOMPARE(request.body.value("language").toString(), QString("fr"));
        QVERIFY(request.headers.toLower().contains("authorization: bearer fixture-token"));
        QVERIFY(request.headers.toLower().contains("x-workspace-id: workspace-a"));
        QCOMPARE(f.remote.count("/api/dispatch/confirm"), 0);
        QTRY_COMPARE(f.remote.count("/api/dispatch/analyze"), 1);
        QVERIFY(!f.mission.opened());
        QCOMPARE(f.mission.instruction(), f.controller.pendingInstruction());
    }
    void englishMessageOverridesStaleFrenchHint() {
        Fixture f;
        f.controller.setLanguage("fr");
        f.controller.sendMessage("Can you check if the website has a good SEO", "fr");
        QTRY_VERIFY(!f.controller.busy());
        QCOMPARE(f.remote.last("/api/orchestrator/chat").body.value("language").toString(), QString("en"));
    }
    void failedReplyPreservesDraftAndRetryDoesNotDuplicateUser() {
        Fixture f; f.remote.failChat = true;
        f.controller.sendMessage("Bonjour", "fr"); QTRY_VERIFY(!f.controller.busy());
        QCOMPARE(f.controller.draft(), QString("Bonjour")); QCOMPARE(f.controller.messages().size(), 1);
        QVERIFY(!f.controller.error().isEmpty());
        f.remote.failChat = false; f.controller.sendMessage(); QTRY_VERIFY(!f.controller.busy());
        QCOMPARE(f.controller.messages().size(), 2);
        QVERIFY(f.remote.last("/api/orchestrator/chat").body.value("conversation").toArray().isEmpty());
    }
    void workspaceSwitchDiscardsPendingResponseAndPrivateState() {
        Fixture f; f.remote.holdChat = true;
        f.controller.sendMessage("Confidential brief", "en"); QTRY_VERIFY(f.remote.held);
        f.api.setWorkspace("workspace-b"); emit f.session.workspaceChanged();
        QVERIFY(!f.controller.busy()); QVERIFY(f.controller.messages().isEmpty()); QVERIFY(f.controller.draft().isEmpty());
        if (f.remote.held) Remote::reply(f.remote.held, {{"data", QJsonObject{{"reply", "Late private reply"}}}});
        QTest::qWait(30); QVERIFY(f.controller.messages().isEmpty());
    }
    void verifiedMissionsSeparateOutputsAndRejectUnknownActions() {
        Fixture f; QSignalSpy open(&f.controller, &OrchestratorController::openTask);
        QTRY_COMPARE(f.controller.missions().size(), 1);
        const auto task = f.controller.missions().first().toMap();
        QCOMPARE(task.value("artifacts").toList().size(), 1);
        QCOMPARE(task.value("artifacts").toList().first().toMap().value("id").toString(), QString("output-a"));
        f.controller.reviewMission("foreign-task"); QCOMPARE(open.size(), 0);
        f.controller.reviewMission("task-a"); QCOMPARE(open.size(), 1);
        f.controller.cancelMission("foreign-task"); QCOMPARE(f.remote.count("/api/orchestrator/missions/foreign-task/stop"), 0);
        f.controller.cancelMission("task-a"); QTRY_COMPARE(f.remote.count("/api/orchestrator/missions/task-a/stop"), 1);
    }
    void conversationPersistsWithinIdentityScope() {
        Fixture f; f.controller.sendMessage("Saved message", "en"); QTRY_VERIFY(!f.controller.busy());
        f.controller.setDraft("Unsent draft");
        f.api.setWorkspace("workspace-b"); emit f.session.workspaceChanged();
        QVERIFY(f.controller.messages().isEmpty());
        f.api.setWorkspace("workspace-a"); emit f.session.workspaceChanged();
        QTRY_COMPARE(f.controller.messages().size(), 2); QCOMPARE(f.controller.draft(), QString("Unsent draft"));
        f.api.setSession("different-token", "other-user", false); emit f.session.changed();
        QVERIFY(f.controller.messages().isEmpty()); QVERIFY(f.controller.draft().isEmpty());
    }
    void newConversationArchivesTheThreadAndStartsEmptyContext() {
        Fixture f;
        f.controller.sendMessage("Saved message", "en"); QTRY_VERIFY(!f.controller.busy());
        QCOMPARE(f.controller.conversations().size(), 1);
        const auto id = f.controller.activeConversationId();
        QVERIFY(!id.isEmpty());
        f.controller.setDraft("Unsent draft");
        f.controller.newConversation();
        QVERIFY(f.controller.messages().isEmpty());
        QVERIFY(f.controller.draft().isEmpty());
        QVERIFY(f.controller.activeConversationId().isEmpty());
        QCOMPARE(f.controller.conversations().size(), 1);
        f.controller.sendMessage("Second topic", "en"); QTRY_VERIFY(!f.controller.busy());
        QVERIFY(f.remote.last("/api/orchestrator/chat").body.value("conversation").toArray().isEmpty());
        QCOMPARE(f.controller.conversations().size(), 2);
        f.controller.openConversation(id);
        QCOMPARE(f.controller.messages().size(), 2);
        QCOMPARE(f.controller.draft(), QString("Unsent draft"));
        QCOMPARE(f.controller.activeConversationId(), id);
    }
    void workRequestAssignsWithoutAskingPermission() {
        Fixture f; f.remote.askInstead = true;
        const auto message = QString("Regarde le SEO de monpetitparfait.fr et dis moi si il est bien référencé");
        f.controller.sendMessage(message, "fr");
        QTRY_VERIFY(!f.controller.busy());
        const auto reply = f.controller.messages().last().toMap().value("body").toString();
        QVERIFY(reply.contains("mission de recherche SEO"));
        QVERIFY(!reply.contains("Veux-tu"));
        QCOMPARE(f.controller.pendingInstruction(), message);
        QTRY_COMPARE(f.remote.count("/api/dispatch/analyze"), 1);
        f.controller.sendMessage("oui", "fr");
        QTRY_VERIFY(!f.controller.busy());
        QCOMPARE(f.remote.count("/api/dispatch/analyze"), 1);
    }
    void offlineDoesNotPretendToRespond() {
        Fixture f; f.api.setOnline(false); f.controller.sendMessage("Bonjour", "fr");
        QVERIFY(!f.controller.ready()); QVERIFY(!f.controller.busy());
        QCOMPARE(f.controller.draft(), QString("Bonjour")); QVERIFY(f.controller.messages().isEmpty());
        QCOMPARE(f.remote.count("/api/orchestrator/chat"), 0);
    }
};
QTEST_GUILESS_MAIN(OrchestratorTests)
#include "orchestrator_controller_tests.moc"
