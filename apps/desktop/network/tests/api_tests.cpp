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
    void invalidJsonNeverBecomesSuccessfulEmptyData() {
        HttpFixture remote; QVERIFY(remote.server.isListening());
        remote.handler = [](QTcpSocket* socket) { HttpFixture::reply(socket, "{malformed"); };
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
    void redirectsNeverForwardCredentials() {
        HttpFixture remote, other; QVERIFY(remote.server.isListening()); QVERIFY(other.server.isListening());
        remote.handler = [&](QTcpSocket* socket) { HttpFixture::reply(socket, "{}", 302, "Location: " + other.origin().toEncoded() + "/api/private\r\n"); };
        ApiClient api(remote.origin()); api.setSession("fixture-secret", "alice", false); api.setWorkspace("workspace-a");
        QObject owner; bool finished = false;
        api.request("GET", "/api/example", {}, mokaid::core::Scope::workspace, &owner, [&](ApiResponse r) { QVERIFY(!r.ok()); QCOMPARE(r.status, 302); finished = true; });
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
