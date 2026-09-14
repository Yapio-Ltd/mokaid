#include <mokaid/network/api_client.hpp>
#include <QJsonDocument>
#include <QPointer>
#include <QTcpServer>
#include <QTcpSocket>
#include <QtTest>
#include <memory>
using namespace mokaid::desktop;
namespace {
class DecoderConstructionObserver final : public QObject {
public:
    std::function<void()> onChild;
    bool eventFilter(QObject*, QEvent* event) override {
        if (event->type() == QEvent::ChildAdded && onChild) onChild();
        return false;
    }
};
class HttpFixture final : public QObject {
public:
    QTcpServer server;
    QPointer<QTcpSocket> peer;
    int count{};
    QByteArray headers;
    std::function<void(QTcpSocket*)> handler;
    HttpFixture() {
        server.listen(QHostAddress::LocalHost, 0);
        connect(&server, &QTcpServer::newConnection, this, [this] {
            while (server.hasPendingConnections()) {
                auto* socket = server.nextPendingConnection(); peer = socket;
                connect(socket, &QTcpSocket::disconnected, socket, &QObject::deleteLater);
                connect(socket, &QTcpSocket::readyRead, this, [this, socket] {
                    auto bytes = socket->property("request").toByteArray() + socket->readAll(); socket->setProperty("request", bytes);
                    if (!bytes.contains("\r\n\r\n") || socket->property("handled").toBool()) return;
                    socket->setProperty("handled", true); headers = bytes; ++count;
                    if (handler) handler(socket);
                });
            }
        });
    }
    QUrl origin() const { return QUrl(QString("http://127.0.0.1:%1").arg(server.serverPort())); }
    static void reply(QTcpSocket* socket, const QByteArray& body, int status = 200, const QByteArray& extra = {}) {
        socket->write("HTTP/1.1 " + QByteArray::number(status) + " Response\r\nConnection: close\r\nContent-Type: application/json\r\n"
            + extra + "Content-Length: " + QByteArray::number(body.size()) + "\r\n\r\n" + body);
        socket->disconnectFromHost();
    }
};
}
class ApiTests final : public QObject {
    Q_OBJECT
private slots:
    void opaqueDownloadsPreserveBytes_data() {
        QTest::addColumn<QByteArray>("body");
        QTest::newRow("json-object") << QByteArray("{\"name\":\"document\"}");
        QTest::newRow("json-array") << QByteArray("[1,2,3]");
        QTest::newRow("json-scalar") << QByteArray("42");
        QTest::newRow("json-malformed") << QByteArray("{unfinished");
        QTest::newRow("binary") << QByteArray("\0\xff\x01\0", 4);
        QTest::newRow("empty-file") << QByteArray{};
        QTest::newRow("large-json-array") << QByteArray("[\"") + QByteArray(400000, 'a') + "\"]";
    }
    void opaqueDownloadsPreserveBytes() {
        QFETCH(QByteArray, body);
        HttpFixture remote; QVERIFY(remote.server.isListening());
        remote.handler = [&](QTcpSocket* socket) { HttpFixture::reply(socket, body); };
        ApiClient api(remote.origin()); api.setSession("fixture-secret", "alice", false); api.setWorkspace("workspace-a");
        QObject owner; bool finished = false; ApiResponse result;
        api.getBytes("/api/example/raw", mokaid::core::Scope::workspace, &owner,
            [&](ApiResponse response) { result = std::move(response); finished = true; });
        QTRY_VERIFY(finished);
        QVERIFY2(result.ok(), qPrintable(result.error)); QCOMPARE(result.bytes, body); QVERIFY(result.json.isEmpty());
        QVERIFY(remote.headers.contains("Accept: */*"));
        QVERIFY(remote.headers.contains("Authorization: Bearer fixture-secret"));
        QVERIFY(remote.headers.toLower().contains("x-workspace-id: workspace-a"));
    }
    void opaqueDownloadsStillDecodeHttpErrors() {
        HttpFixture remote; QVERIFY(remote.server.isListening());
        remote.handler = [](QTcpSocket* socket) { HttpFixture::reply(socket, "{\"error\":{\"message\":\"File access denied\"}}", 403); };
        ApiClient api(remote.origin()); api.setSession("fixture-secret", "alice", true);
        QSignalSpy denied(&api, &ApiClient::administratorDenied);
        QObject owner; bool finished = false; ApiResponse result;
        api.getBytes("/api/example/raw", mokaid::core::Scope::administration, &owner,
            [&](ApiResponse response) { result = std::move(response); finished = true; });
        QTRY_VERIFY(finished); QVERIFY(!result.ok()); QCOMPARE(result.error, "File access denied");
        QVERIFY(!result.networkError); QVERIFY(api.context().online); QCOMPARE(denied.size(), 1);
        QVERIFY(!api.context().platform_admin);
    }
    void opaqueNoContentResponseIsAnEmptySuccess() {
        HttpFixture remote; QVERIFY(remote.server.isListening());
        remote.handler = [](QTcpSocket* socket) { HttpFixture::reply(socket, {}, 204); };
        ApiClient api(remote.origin()); QObject owner; bool finished = false;
        api.getBytes("/api/example/raw", mokaid::core::Scope::public_api, &owner, [&](ApiResponse response) {
            QVERIFY(response.ok()); QCOMPARE(response.status, 204); QVERIFY(response.bytes.isEmpty()); finished = true;
        });
        QTRY_VERIFY(finished);
    }
    void opaqueDownloadExpiryInvalidatesSession() {
        HttpFixture remote; QVERIFY(remote.server.isListening());
        remote.handler = [](QTcpSocket* socket) { HttpFixture::reply(socket, "{\"error\":\"Session expired\"}", 401); };
        ApiClient api(remote.origin()); api.setSession("fixture-secret", "alice", false); api.setWorkspace("workspace-a");
        QSignalSpy expired(&api, &ApiClient::sessionExpired);
        QObject owner; bool finished = false;
        api.getBytes("/api/example/raw", mokaid::core::Scope::workspace, &owner,
            [&](ApiResponse response) { QVERIFY(!response.ok()); QCOMPARE(response.error, "Session expired"); finished = true; });
        QTRY_VERIFY(finished); QCOMPARE(expired.size(), 1);
    }
    void opaqueDownloadsRejectOversizedPayloads() {
        HttpFixture remote; QVERIFY(remote.server.isListening());
        remote.handler = [](QTcpSocket* socket) { HttpFixture::reply(socket, QByteArray(32 * 1024 * 1024 + 1, 'x')); };
        ApiClient api(remote.origin()); QObject owner; bool finished = false; ApiResponse result;
        api.getBytes("/api/example/raw", mokaid::core::Scope::public_api, &owner,
            [&](ApiResponse response) { result = std::move(response); finished = true; });
        QTRY_VERIFY(finished); QVERIFY(!result.ok()); QVERIFY(result.bytes.isEmpty());
        QVERIFY(result.error.contains("safe size limit")); QVERIFY(!result.error.contains("browser"));
    }
    void opaqueDownloadsRejectOfflineAndUnsafeRequests() {
        HttpFixture remote; QVERIFY(remote.server.isListening());
        ApiClient api(remote.origin()); api.setSession("fixture-secret", "alice", false); api.setWorkspace("workspace-a");
        QObject owner; int callbacks = 0;
        const auto rejected = [&](ApiResponse response) { QVERIFY(!response.ok()); ++callbacks; };
        api.setOnline(false);
        api.getBytes("/api/example/raw", mokaid::core::Scope::workspace, &owner, rejected);
        api.setOnline(true);
        api.getBytes("//example.com/api/raw", mokaid::core::Scope::workspace, &owner, rejected);
        api.getBytes("/api/../private", mokaid::core::Scope::workspace, &owner, rejected);
        api.getBytes("/api/example/raw", mokaid::core::Scope::administration, &owner, rejected);
        api.reset();
        api.getBytes("/api/example/raw", mokaid::core::Scope::workspace, &owner, rejected);
        QCOMPARE(callbacks, 5); QCOMPARE(remote.count, 0);
    }
    void cancelledOpaqueDownloadsCannotReachTheOldOwner_data() {
        QTest::addColumn<QString>("transition");
        for (const auto* name : {"owner", "account", "workspace", "reset", "request"})
            QTest::newRow(name) << QString::fromLatin1(name);
    }
    void cancelledOpaqueDownloadsCannotReachTheOldOwner() {
        QFETCH(QString, transition);
        HttpFixture remote; QVERIFY(remote.server.isListening());
        ApiClient api(remote.origin()); api.setSession("fixture-secret", "alice", false); api.setWorkspace("workspace-a");
        auto owner = std::make_unique<QObject>(); bool finished = false;
        api.getBytes("/api/example/raw", mokaid::core::Scope::workspace, owner.get(), [&](ApiResponse) { finished = true; });
        QTRY_COMPARE(remote.count, 1);
        if (transition == "owner") owner.reset();
        else if (transition == "account") api.setSession("fixture-other", "bob", false);
        else if (transition == "workspace") api.setWorkspace("workspace-b");
        else if (transition == "reset") api.reset();
        else api.cancelRequests(owner.get());
        QTRY_VERIFY(!remote.peer || remote.peer->state() == QAbstractSocket::UnconnectedState);
        QTest::qWait(50); QVERIFY(!finished);
    }
    void interruptedSuccessfulResponseNeverReturnsPartialData_data() {
        QTest::addColumn<bool>("opaque");
        QTest::newRow("json-api") << false;
        QTest::newRow("opaque-download") << true;
    }
    void interruptedSuccessfulResponseNeverReturnsPartialData() {
        QFETCH(bool, opaque);
        HttpFixture remote; QVERIFY(remote.server.isListening());
        remote.handler = [](QTcpSocket* socket) {
            socket->write("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Type: application/octet-stream\r\nContent-Length: 100\r\n\r\npartial");
            socket->disconnectFromHost();
        };
        ApiClient api(remote.origin()); QObject owner; bool finished = false; ApiResponse result;
        auto complete = [&](ApiResponse response) { result = std::move(response); finished = true; };
        if (opaque) api.getBytes("/api/example/raw", mokaid::core::Scope::public_api, &owner, complete);
        else api.request("GET", "/api/example/raw", {}, mokaid::core::Scope::public_api, &owner, complete);
        QTRY_VERIFY(finished);
        QVERIFY(!result.ok()); QVERIFY(result.networkError); QVERIFY(result.bytes.isEmpty());
    }
    void invalidJsonNeverBecomesSuccessfulEmptyData_data() {
        QTest::addColumn<QByteArray>("body");
        QTest::newRow("malformed") << QByteArray("{malformed");
        QTest::newRow("array-not-api-envelope") << QByteArray("[1,2,3]");
        QTest::newRow("scalar-not-api-envelope") << QByteArray("42");
    }
    void invalidJsonNeverBecomesSuccessfulEmptyData() {
        QFETCH(QByteArray, body);
        HttpFixture remote; QVERIFY(remote.server.isListening());
        remote.handler = [&](QTcpSocket* socket) { HttpFixture::reply(socket, body); };
        ApiClient api(remote.origin()); QObject owner; bool finished = false; ApiResponse result;
        api.request("GET", "/api/example", {}, mokaid::core::Scope::public_api, &owner, [&](ApiResponse r) { result = std::move(r); finished = true; });
        QTRY_VERIFY(finished); QVERIFY(!result.ok()); QVERIFY(result.error.contains("invalid JSON"));
    }
    void largeJsonDecodedOffThreadReturnsToOwnerThread() {
        HttpFixture remote; QVERIFY(remote.server.isListening());
        remote.handler = [](QTcpSocket* socket) { HttpFixture::reply(socket, QJsonDocument(QJsonObject{{"data", QString(400000, 'a')}}).toJson()); };
        ApiClient api(remote.origin()); QObject owner; bool finished = false;
        api.request("GET", "/api/example", {}, mokaid::core::Scope::public_api, &owner, [&](ApiResponse r) {
            QCOMPARE(QThread::currentThread(), owner.thread()); QVERIFY(r.ok()); QCOMPARE(r.json.value("data").toString().size(), 400000); finished = true;
        });
        QTRY_VERIFY(finished);
    }
    void oversizedJsonIsRejectedWithoutCachingPayload() {
        HttpFixture remote; QVERIFY(remote.server.isListening());
        remote.handler = [](QTcpSocket* socket) { HttpFixture::reply(socket, QByteArray(8 * 1024 * 1024 + 1, 'x')); };
        ApiClient api(remote.origin()); QObject owner; bool finished = false;
        api.request("GET", "/api/example", {}, mokaid::core::Scope::public_api, &owner, [&](ApiResponse r) {
            QVERIFY(!r.ok()); QVERIFY(r.error.contains("safe size limit")); QVERIFY(r.bytes.isEmpty()); finished = true;
        });
        QTRY_VERIFY(finished);
    }
    void redirectsNeverForwardCredentials_data() {
        QTest::addColumn<bool>("opaque");
        QTest::newRow("json-api") << false;
        QTest::newRow("opaque-download") << true;
    }
    void redirectsNeverForwardCredentials() {
        QFETCH(bool, opaque);
        HttpFixture remote, other; QVERIFY(remote.server.isListening()); QVERIFY(other.server.isListening());
        remote.handler = [&](QTcpSocket* socket) { HttpFixture::reply(socket, "{}", 302, "Location: " + other.origin().toEncoded() + "/api/private\r\n"); };
        ApiClient api(remote.origin()); api.setSession("fixture-secret", "alice", false); api.setWorkspace("workspace-a");
        QObject owner; bool finished = false;
        auto complete = [&](ApiResponse r) { QVERIFY(!r.ok()); QCOMPARE(r.status, 302); finished = true; };
        if (opaque) api.getBytes("/api/example", mokaid::core::Scope::workspace, &owner, complete);
        else api.request("GET", "/api/example", {}, mokaid::core::Scope::workspace, &owner, complete);
        QTRY_VERIFY(finished); QTest::qWait(100); QCOMPARE(other.count, 0);
        QVERIFY(remote.headers.contains("Authorization: Bearer fixture-secret")); QVERIFY(remote.headers.toLower().contains("x-workspace-id: workspace-a"));
    }
    void destroyingOwnerCancelsWithoutCallback() {
        HttpFixture remote; QVERIFY(remote.server.isListening()); ApiClient api(remote.origin());
        auto owner = std::make_unique<QObject>(); bool completed = false;
        api.request("GET", "/api/example", {}, mokaid::core::Scope::public_api, owner.get(), [&](ApiResponse) { completed = true; });
        QTRY_COMPARE(remote.count, 1); owner.reset();
        QTRY_VERIFY(!remote.peer || remote.peer->state() == QAbstractSocket::UnconnectedState); QVERIFY(!completed);
    }
    void cancellationStillAppliesAfterTransferBeforeDecoderCompletes() {
        HttpFixture remote; QVERIFY(remote.server.isListening());
        remote.handler = [](QTcpSocket* socket) { HttpFixture::reply(socket, QJsonDocument(QJsonObject{{"data", QString(400000, 'a')}}).toJson()); };
        ApiClient api(remote.origin()); QObject owner; bool decoderCreated = false, completed = false;
        // The decoder watcher is parented to ApiClient only after transfer completion.
        // Cancel at its construction, before the async result can be delivered.
        DecoderConstructionObserver observer;
        observer.onChild = [&] { decoderCreated = true; api.cancelRequests(&owner); };
        api.installEventFilter(&observer);
        api.request("GET", "/api/example", {}, mokaid::core::Scope::public_api, &owner, [&](ApiResponse) { completed = true; });
        QTRY_VERIFY(decoderCreated); QTest::qWait(200); QVERIFY(!completed);
    }
};
QTEST_GUILESS_MAIN(ApiTests)
#include "api_tests.moc"
