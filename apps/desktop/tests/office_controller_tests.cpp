#include <mokaid/application/office_controller.hpp>
#include <QJsonDocument>
#include <QPointer>
#include <QSettings>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QUrlQuery>
#include <QtTest>

using namespace mokaid::desktop;
namespace {
struct Request { QString method, path; QJsonObject body; QByteArray headers; };
QJsonObject message(QString id, QString conversation = "current", QString body = "Final reply") {
    return {{"id", id}, {"agent_id", "agent-a"}, {"conversation_id", conversation}, {"body", body},
            {"author_kind", "agent"}, {"inserted_at", "2026-09-14T10:00:00Z"}};
}
class OfficeApi final : public QObject {
public:
    QTcpServer server;
    QList<Request> requests;
    QJsonArray history;
    QString active = "current";
    std::function<bool(QTcpSocket*, const Request&)> handler;
    OfficeApi() {
        server.listen(QHostAddress::LocalHost, 0);
        connect(&server, &QTcpServer::newConnection, this, [this] {
            while (server.hasPendingConnections()) {
                auto* socket = server.nextPendingConnection();
                connect(socket, &QTcpSocket::disconnected, socket, &QObject::deleteLater);
                connect(socket, &QTcpSocket::readyRead, this, [this, socket] {
                    auto bytes = socket->property("request").toByteArray() + socket->readAll();
                    socket->setProperty("request", bytes);
                    const auto end = bytes.indexOf("\r\n\r\n");
                    if (end < 0 || socket->property("handled").toBool()) return;
                    qsizetype size = 0;
                    for (const auto& line : bytes.left(end).split('\n'))
                        if (line.toLower().startsWith("content-length:")) size = line.mid(15).trimmed().toLongLong();
                    if (bytes.size() < end + 4 + size) return;
                    socket->setProperty("handled", true);
                    const auto line = bytes.left(bytes.indexOf("\r\n")).split(' ');
                    Request request{QString::fromUtf8(line.value(0)), QString::fromUtf8(line.value(1)),
                        QJsonDocument::fromJson(bytes.mid(end + 4, size)).object(), bytes.left(end)};
                    requests.append(request);
                    if (handler && handler(socket, request)) return;
                    if (request.path == "/api/agents") reply(socket, {{"data", QJsonArray{
                        QJsonObject{{"id", "agent-a"}, {"display_name", "Alice"}},
                        QJsonObject{{"id", "agent-b"}, {"display_name", "Bob"}}}}});
                    else if (request.path.endsWith("/conversations")) {
                        const auto agent = request.path.split('/').value(3);
                        reply(socket, {{"data", QJsonArray{
                            QJsonObject{{"id", active}, {"agent_id", agent}, {"status", "active"}},
                            QJsonObject{{"id", "archived"}, {"agent_id", agent}, {"status", "archived"}}}}});
                    } else if (request.method == "GET") reply(socket, {{"data", history}});
                    else reply(socket, {{"data", QJsonObject{}}});
                });
            }
        });
    }
    QUrl origin() const { return QUrl(QString("http://127.0.0.1:%1").arg(server.serverPort())); }
    int count(const QString& part) const {
        int result = 0;
        for (const auto& request : requests) if (request.path.contains(part)) ++result;
        return result;
    }
    static void reply(QTcpSocket* socket, const QJsonObject& object, int status = 200) {
        const auto json = QJsonDocument(object).toJson(QJsonDocument::Compact);
        socket->write("HTTP/1.1 " + QByteArray::number(status) + " Response\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: " +
            QByteArray::number(json.size()) + "\r\n\r\n" + json);
        socket->disconnectFromHost();
    }
};
struct Fixture {
    OfficeApi remote;
    QTemporaryDir directory;
    CacheStore cache{directory.path()};
    ApiClient api{remote.origin()};
    PhoenixClient realtime;
    SessionController session{api, realtime};
    OfficeController office{api, session, realtime, cache};
    Fixture() {
        api.setSession("fixture-token", "alice", false); api.setWorkspace("workspace-a");
        emit session.changed();
    }
    void chunk(QString id, QString text, QString conversation = "current", bool done = false, QString topic = "workspace:workspace-a") {
        emit realtime.eventReceived(topic, "agent_chat.chunk", {{"agent_id", "agent-a"}, {"conversation_id", conversation},
            {"stream_id", id}, {"chunk", text}, {"done", done}});
    }
    void final(QString id, QString stream = {}, QString conversation = "current", QString body = "Final reply",
               QString topic = "workspace:workspace-a") {
        emit realtime.eventReceived(topic, "agent_chat.message", {{"agent_id", "agent-a"}, {"conversation_id", conversation},
            {"stream_id", stream}, {"message", message(id, conversation, body)}});
    }
};
}

class OfficeTests final : public QObject {
    Q_OBJECT
    QTemporaryDir preferences_;
private slots:
    void initTestCase() {
        QVERIFY(preferences_.isValid());
        QCoreApplication::setOrganizationName("MokaidOfficeTests");
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, preferences_.path());
    }
    void emptyCurrentIsIsolatedFromArchivedAndOtherWorkspace() {
        Fixture f; QTRY_COMPARE(f.office.agents().size(), 2);
        f.office.selectAgent("agent-a"); QTRY_VERIFY(!f.office.loading());
        f.final("old", {}, "archived"); f.final("foreign", {}, "current", "Secret", "workspace:other");
        f.chunk("unscoped", "Unknown", {}); f.chunk("old-stream", "Old", "archived");
        QTest::qWait(100); QVERIFY(f.office.messages().isEmpty()); QVERIFY(f.office.stream().isEmpty());
        f.final("current-message"); QCOMPARE(f.office.messages().size(), 1);
        f.final("current-message", {}, "current", "Updated"); QCOMPARE(f.office.messages().size(), 1);
        QCOMPARE(f.office.messages().first().toMap().value("body").toString(), QString("Updated"));
        f.office.selectConversation("archived"); QVERIFY(f.office.messages().isEmpty());
        QTRY_VERIFY(!f.office.loading()); f.final("old-visible", {}, "archived"); f.final("new-hidden");
        QCOMPARE(f.office.messages().size(), 1);
        QCOMPARE(f.office.messages().first().toMap().value("id").toString(), QString("old-visible"));
    }
    void independentStreamsFinalizeOnlyTheirOwnMessage() {
        Fixture f; QTRY_COMPARE(f.office.agents().size(), 2);
        f.office.selectAgent("agent-a"); QTRY_VERIFY(!f.office.loading());
        f.chunk("one", "One"); f.chunk("two", "Two"); QTRY_COMPARE(f.office.stream(), QString("One\n\nTwo"));
        f.final("unrelated"); QCOMPARE(f.office.stream(), QString("One\n\nTwo"));
        f.final("first", "one"); QCOMPARE(f.office.stream(), QString("Two"));
        f.chunk("one", "Late"); QTest::qWait(50); QCOMPARE(f.office.stream(), QString("Two"));
        f.chunk("two", "!", "current", true); QTRY_COMPARE(f.office.stream(), QString("Two!"));
        QTest::qWait(100); QCOMPARE(f.office.stream(), QString("Two!"));
        f.final("second", "two"); QVERIFY(f.office.stream().isEmpty());
        f.chunk("two", "Late after done"); QTest::qWait(50); QVERIFY(f.office.stream().isEmpty());
    }
    void snapshotCannotEraseChannelMessageAndLatestRequestWins() {
        Fixture f; QTRY_COMPARE(f.office.agents().size(), 2); QPointer<QTcpSocket> pending;
        f.remote.handler = [&](QTcpSocket* socket, const Request& request) {
            if (request.method == "GET" && request.path.contains("/chat?")) { pending = socket; return true; }
            return false;
        };
        f.office.selectAgent("agent-a"); QTRY_VERIFY(pending);
        f.final("realtime", {}, "current", "Newest"); QCOMPARE(f.office.messages().size(), 1);
        OfficeApi::reply(pending, {{"data", QJsonArray{message("realtime", "current", "Old HTTP")}}});
        QTRY_VERIFY(!f.office.loading());
        QCOMPARE(f.office.messages().first().toMap().value("body").toString(), QString("Newest"));
        pending.clear(); f.office.refreshMessages(); QTRY_VERIFY(pending);
        const QPointer<QTcpSocket> stale = pending;
        f.remote.handler = {}; f.remote.history = {message("archived-message", "archived")};
        f.office.selectConversation("archived"); QVERIFY(f.office.messages().isEmpty());
        QTRY_VERIFY(!f.office.loading()); QTRY_VERIFY(!stale || stale->state() == QAbstractSocket::UnconnectedState);
        QCOMPARE(f.office.messages().size(), 1); QVERIFY(f.office.error().isEmpty());
    }
    void reconnectReloadsCanonicalHistoryAndRetiresInterruptedStreams() {
        Fixture f; QTRY_COMPARE(f.office.agents().size(), 2);
        f.office.selectAgent("agent-a"); QTRY_VERIFY(!f.office.loading());
        f.chunk("interrupted", "Partial"); QTRY_COMPARE(f.office.stream(), QString("Partial"));
        emit f.realtime.connectionChanged(false); QVERIFY(f.office.stream().isEmpty());
        f.remote.history = {message("persisted")}; const auto before = f.remote.count("/conversations");
        emit f.realtime.rejoined(); QTRY_VERIFY(f.remote.count("/conversations") > before);
        QTRY_COMPARE(f.office.messages().size(), 1);
        f.chunk("interrupted", "Late"); QTest::qWait(50); QVERIFY(f.office.stream().isEmpty());
        f.chunk("fresh", "New"); QTRY_COMPARE(f.office.stream(), QString("New"));
    }
    void identicalStreamsCannotBeFinalizedByTheSameRestMessage() {
        Fixture f; f.remote.history = {message("prior", "current", "Same reply")};
        QTRY_COMPARE(f.office.agents().size(), 2);
        f.office.selectAgent("agent-a"); QTRY_COMPARE(f.office.messages().size(), 1);
        f.chunk("one", "Same reply", "current", true);
        f.chunk("two", "Same reply", "current", true);
        QTRY_COMPARE(f.office.stream(), QString("Same reply\n\nSame reply"));
        f.remote.history.append(message("new-final", "current", "Same reply"));
        f.office.refreshMessages(); QTRY_COMPARE(f.office.messages().size(), 2);
        QCOMPARE(f.office.stream(), QString("Same reply\n\nSame reply"));
        f.final("new-final", "one", "current", "Same reply"); QCOMPARE(f.office.stream(), QString("Same reply"));
        f.office.refreshMessages(); QTest::qWait(100); QCOMPARE(f.office.stream(), QString("Same reply"));
        f.final("other-final", "two", "current", "Same reply"); QVERIFY(f.office.stream().isEmpty());
        f.chunk("one", "Late"); f.chunk("two", "Late"); QTest::qWait(50); QVERIFY(f.office.stream().isEmpty());
    }
    void accountAndWorkspaceChangesEraseDraftsAndPartitionOfflineCache() {
        Fixture f; f.remote.history = {message("private")}; QTRY_COMPARE(f.office.agents().size(), 2);
        f.office.selectAgent("agent-a"); QTRY_COMPARE(f.office.messages().size(), 1);
        f.final("channel-only-final"); QCOMPARE(f.office.messages().size(), 2);
        f.office.setDraft("Private draft"); f.api.setOnline(false); f.office.closeChat();
        f.office.selectAgent("agent-a"); QTRY_COMPARE(f.office.messages().size(), 2);
        QCOMPARE(f.office.draft(), QString("Private draft"));
        f.api.setSession("fixture-bob", "bob", false); emit f.session.changed();
        QVERIFY(f.office.messages().isEmpty()); QVERIFY(!f.office.hasDrafts()); QVERIFY(f.office.agents().isEmpty());
        QTest::qWait(100); QVERIFY(f.office.agents().isEmpty());
        f.api.setSession("fixture-token", "alice", false); f.api.setWorkspace("workspace-b"); emit f.session.workspaceChanged();
        QTest::qWait(100); QVERIFY(f.office.agents().isEmpty());
        f.api.setWorkspace("workspace-a"); emit f.session.workspaceChanged(); QTRY_COMPARE(f.office.agents().size(), 2);
        f.office.selectAgent("agent-a"); QTRY_COMPARE(f.office.messages().size(), 2); QVERIFY(f.office.draft().isEmpty());
    }
    void oldMutationCannotClearNewDraftOrSendingState() {
        Fixture f; QTRY_COMPARE(f.office.agents().size(), 2);
        f.office.selectAgent("agent-a"); QTRY_VERIFY(!f.office.loading());
        QPointer<QTcpSocket> pending;
        f.remote.handler = [&](QTcpSocket* socket, const Request& request) {
            if (request.method == "POST" && request.path.endsWith("/chat")) { pending = socket; return true; }
            return false;
        };
        f.office.setDraft("First"); f.office.send(); QTRY_VERIFY(pending); QVERIFY(f.office.sending());
        const QPointer<QTcpSocket> old = pending;
        f.office.closeChat(); QVERIFY(!f.office.sending()); QVERIFY(!f.office.loading());
        f.office.selectAgent("agent-a"); QTRY_VERIFY(!f.office.loading());
        f.office.setDraft("Second"); pending.clear(); f.office.send(); QTRY_VERIFY(pending);
        QTRY_VERIFY(!old || old->state() == QAbstractSocket::UnconnectedState);
        QVERIFY(f.office.sending()); QCOMPARE(f.office.draft(), QString("Second"));
        OfficeApi::reply(pending, {{"data", message("sent")}}); QTRY_VERIFY(!f.office.sending()); QVERIFY(f.office.draft().isEmpty());
    }
    void boundedStreamsAndNoLateDraftAfterNavigation() {
        Fixture f; QTRY_COMPARE(f.office.agents().size(), 2);
        f.office.selectAgent("agent-a"); QTRY_VERIFY(!f.office.loading());
        for (int i = 0; i < 20; ++i) f.chunk(QString::number(i), QString(150000, 'x'));
        QTRY_VERIFY(!f.office.stream().isEmpty()); QVERIFY(f.office.stream().size() <= 1000014);
        f.office.selectConversation("archived"); QVERIFY(f.office.stream().isEmpty()); QTRY_VERIFY(!f.office.loading());
        f.office.selectConversation({}); QTRY_VERIFY(!f.office.loading()); f.chunk("0", "Late");
        QTest::qWait(50); QVERIFY(f.office.stream().isEmpty());
    }
    void ninthStreamReclaimsCapacityWithoutLosingOtherStreamsOrCanonicalFinals() {
        Fixture f; QTRY_COMPARE(f.office.agents().size(), 2);
        f.office.selectAgent("agent-a"); QTRY_VERIFY(!f.office.loading());
        for (int i = 0; i < 8; ++i) f.chunk(QString("stream-%1").arg(i), QString("Preview %1").arg(i));
        QTRY_COMPARE(f.office.stream().split("\n\n").size(), 8);
        const auto before = f.remote.count("/conversations");
        f.chunk("ninth", "Newest preview");
        QTRY_VERIFY(f.office.stream().contains("Newest preview"));
        QVERIFY(!f.office.stream().contains("Preview 0"));
        for (int i = 1; i < 8; ++i) QVERIFY(f.office.stream().contains(QString("Preview %1").arg(i)));
        QCOMPARE(f.office.stream().split("\n\n").size(), 8);
        QTRY_VERIFY(f.remote.count("/conversations") > before);
        QTest::qWait(100); QVERIFY(f.office.error().contains("older live response preview was hidden"));
        const auto visible = f.office.stream();
        f.chunk("stream-0", "Late ignored chunk"); QTest::qWait(50); QCOMPARE(f.office.stream(), visible);
        f.final("old-canonical", "stream-0", "current", "Recovered original reply");
        QCOMPARE(f.office.messages().size(), 1);
        QCOMPARE(f.office.messages().first().toMap().value("body").toString(), QString("Recovered original reply"));
        QCOMPARE(f.office.stream(), visible);
        f.chunk("ninth", " continues"); QTRY_VERIFY(f.office.stream().contains("Newest preview continues"));
        f.final("new-canonical", "ninth"); QCOMPARE(f.office.messages().size(), 2);
        QVERIFY(!f.office.stream().contains("Newest preview"));
        for (int i = 1; i < 8; ++i) QVERIFY(f.office.stream().contains(QString("Preview %1").arg(i)));
    }
    void lateNewConversationDoesNotNavigateOrOverwriteErrors() {
        Fixture f; QTRY_COMPARE(f.office.agents().size(), 2);
        f.office.selectAgent("agent-a"); QTRY_VERIFY(!f.office.loading());
        QPointer<QTcpSocket> pending;
        f.remote.handler = [&](QTcpSocket* socket, const Request& request) {
            if (request.path.endsWith("/conversations/new")) { pending = socket; return true; }
            return false;
        };
        f.office.newConversation(); QTRY_VERIFY(pending); QVERIFY(f.office.sending());
        f.office.selectAgent("agent-b"); QTRY_VERIFY(!f.office.loading());
        f.office.setDraft("Bob draft");
        QTRY_VERIFY(!pending || pending->state() == QAbstractSocket::UnconnectedState);
        QCOMPARE(f.office.selectedAgent().value("id").toString(), QString("agent-b"));
        QCOMPARE(f.office.draft(), QString("Bob draft")); QVERIFY(!f.office.sending());
        QVERIFY(f.office.error().isEmpty());
    }
    void destructionCancelsOnlyOwnedRequests() {
        OfficeApi remote; QTemporaryDir directory; CacheStore cache(directory.path());
        ApiClient api(remote.origin()); api.setSession("fixture", "alice", false); api.setWorkspace("workspace-a");
        PhoenixClient realtime; SessionController session(api, realtime); QObject otherOwner;
        QPointer<QTcpSocket> owned, unrelated;
        remote.handler = [&](QTcpSocket* socket, const Request& request) {
            if (request.path == "/api/agents") owned = socket; else unrelated = socket;
            return true;
        };
        auto office = std::make_unique<OfficeController>(api, session, realtime, cache);
        office->refresh(); bool completed = false;
        api.request("GET", "/api/unrelated", {}, mokaid::core::Scope::workspace, &otherOwner, [&](ApiResponse response) { completed = response.ok(); });
        QTRY_VERIFY(owned && unrelated); office.reset();
        QTRY_VERIFY(!owned || owned->state() == QAbstractSocket::UnconnectedState);
        QVERIFY(unrelated && unrelated->state() == QAbstractSocket::ConnectedState);
        OfficeApi::reply(unrelated, {{"data", QJsonArray{}}}); QTRY_VERIFY(completed);
    }
};
QTEST_GUILESS_MAIN(OfficeTests)
#include "office_controller_tests.moc"
