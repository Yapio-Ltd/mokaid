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
    bool failChat{}, holdChat{}, askInstead{}, mailAnswer{}, legalDispatch{}, partialDispatch{};
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
                        if (mailAnswer) {
                            reply(socket, {{"data", QJsonObject{{"reply", "J'ai trouvé deux factures dans les messages synchronisés. Veux-tu le détail ?"},
                                {"language", "fr"}, {"response_kind", "answer"}, {"mission_instruction", ""}}}});
                            return;
                        }
                        if (askInstead) {
                            reply(socket, {{"data", QJsonObject{{"reply", "Je peux préparer une mission de recherche SEO. Veux-tu que je prépare cette mission d'audit SEO ?"}, {"language", "fr"}}}});
                            return;
                        }
                        if (legalDispatch) {
                            reply(socket, {{"data", QJsonObject{{"reply", "Je prépare le récapitulatif juridique demandé."},
                                {"language", "fr"}, {"mission_instruction", request.body.value("message")}}}});
                            return;
                        }
                        reply(socket, {{"data", QJsonObject{{"reply", "Voici la mission à préparer."}, {"language", "fr"},
                            {"mission_instruction", "Étudier le marché et livrer un rapport sourcé."}, {"task_id", "foreign-task"}}}});
                    } else if (legalDispatch && request.path == "/api/agents") {
                        reply(socket, {{"data", QJsonArray{
                            QJsonObject{{"id", "sira"}, {"display_name", "Sira"}, {"role_title", "Software Engineer"},
                                {"kind", "ai"}, {"status", "idle"}, {"ai_enabled", true}},
                            QJsonObject{{"id", "taya"}, {"display_name", "Taya"}, {"role_title", "Legal Specialist"},
                                {"kind", "ai"}, {"status", "idle"}, {"ai_enabled", true}}}}});
                    } else if (legalDispatch && request.path == "/api/dispatch/analyze") {
                        QJsonObject route{{"mode", partialDispatch ? "user_choice" : "existing_agent"},
                            {"agent_id", partialDispatch ? "sira" : "taya"}, {"confidence", partialDispatch ? 55 : 95},
                            {"reason", "Le récapitulatif des lois exige des compétences juridiques."},
                            {"alternatives", QJsonArray{}}, {"custom_agent", QJsonValue(QJsonValue::Null)}};
                        if (partialDispatch) route.insert("custom_agent", QJsonObject{
                            {"display_name", "Legal specialist"}, {"role_title", "Legal Specialist"}, {"archetype_key", "legal"},
                            {"skills", QJsonArray{QJsonObject{{"name", "Israeli company law"}, {"level", 40}}}}});
                        reply(socket, {{"data", QJsonObject{
                            {"task", QJsonObject{{"title", "Lois pour les olim créateurs d’entreprise"},
                                {"description", request.body.value("instruction")}, {"priority", "medium"}}},
                            {"recommendation", route}, {"mcp_suggestions", QJsonArray{}}}}});
                    } else if (legalDispatch && request.path == "/api/dispatch/confirm") {
                        const auto agentId = request.body.value("agent_id").toString();
                        reply(socket, {{"data", QJsonObject{
                            {"task", QJsonObject{{"id", "task-legal"}, {"title", "Lois pour les olim créateurs d’entreprise"},
                                {"assigned_agent_id", agentId}}},
                            {"agent", QJsonObject{{"id", agentId}, {"display_name", agentId == "taya" ? "Taya" : "Sira"}}},
                            {"run_id", "run-legal"}}}}, 201);
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
    void legalMissionUsesRecommendedAgentRatherThanFirstRosterEntry() {
        Fixture f; f.remote.legalDispatch = true;
        const auto instruction = QString("Fais moi un recap des lois pour les olim hadashim qui ouvrent une societer en israel");
        f.controller.sendMessage(instruction, "fr");
        QTRY_COMPARE(f.controller.assignmentPhase(), QString("assigned"));
        QCOMPARE(f.remote.count("/api/dispatch/confirm"), 1);
        QCOMPARE(f.remote.last("/api/dispatch/analyze").body.value("instruction").toString(), instruction);
        QCOMPARE(f.remote.last("/api/dispatch/confirm").body.value("agent_id").toString(), QString("taya"));
        QCOMPARE(f.controller.assignmentAgentId(), QString("taya"));
        QCOMPARE(f.controller.assignmentTaskId(), QString("task-legal"));
        const auto selected = f.controller.assignmentAgents().first().toMap();
        QCOMPARE(selected.value("id").toString(), QString("taya"));
        QCOMPARE(selected.value("display_name").toString(), QString("Taya"));
        QCOMPARE(selected.value("role_title").toString(), QString("Legal Specialist"));
    }
    void partialAgentRecommendationRequiresReviewWithoutAutomaticLaunch() {
        Fixture f; f.remote.legalDispatch = true; f.remote.partialDispatch = true;
        f.controller.sendMessage("Fais un recap des lois pour ouvrir une société en Israël", "fr");
        QTRY_COMPARE(f.controller.assignmentPhase(), QString("unmatched"));
        QCOMPARE(f.controller.assignmentAgentId(), QString("sira"));
        QVERIFY(!f.mission.capabilityWarning().isEmpty());
        QTest::qWait(1400);
        QCOMPARE(f.remote.count("/api/dispatch/confirm"), 0);
    }
    void changedSelectionCannotUseAnEarlierAutomaticLaunchTimer() {
        Fixture f; f.remote.legalDispatch = true;
        f.controller.sendMessage("Fais un recap des lois pour ouvrir une société en Israël", "fr");
        QTRY_COMPARE(f.controller.assignmentPhase(), QString("chosen"));
        QCOMPARE(f.controller.assignmentAgentId(), QString("taya"));
        QTRY_COMPARE(f.mission.roster().size(), 2);
        f.mission.selectAgent("sira");
        QCOMPARE(f.controller.assignmentPhase(), QString("unmatched"));
        QVERIFY(!f.mission.capabilityWarning().isEmpty());
        QTest::qWait(1400);
        QCOMPARE(f.remote.count("/api/dispatch/confirm"), 0);
        QCOMPARE(f.controller.assignmentPhase(), QString("unmatched"));
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
    void groundedMailAnswerDoesNotBecomeMissionOrConfirmationFallback() {
        Fixture f; f.remote.mailAnswer = true;
        f.controller.sendMessage("Cherche les factures dans mes mails", "fr");
        QTRY_VERIFY(!f.controller.busy());
        QCOMPARE(f.controller.messages().size(), 2);
        QVERIFY(f.controller.messages().last().toMap().value("body").toString().contains("deux factures"));
        QVERIFY(f.controller.pendingInstruction().isEmpty());
        QCOMPARE(f.remote.count("/api/dispatch/analyze"), 0);
        f.controller.sendMessage("oui", "fr");
        QTRY_VERIFY(!f.controller.busy());
        QVERIFY(f.controller.pendingInstruction().isEmpty());
        QCOMPARE(f.remote.count("/api/dispatch/analyze"), 0);
        QCOMPARE(f.remote.count("/api/dispatch/confirm"), 0);
        // An answered read stays an answer after persistence, even if its
        // wording contains a clarification that resembles an old proposal.
        f.api.setWorkspace("workspace-b"); emit f.session.workspaceChanged();
        f.api.setWorkspace("workspace-a"); emit f.session.workspaceChanged();
        QTRY_COMPARE(f.controller.messages().size(), 4);
        QCOMPARE(f.controller.messages().last().toMap().value("response_kind").toString(), QString("answer"));
        QVERIFY(f.controller.pendingInstruction().isEmpty());
        QCOMPARE(f.remote.count("/api/dispatch/analyze"), 0);
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
