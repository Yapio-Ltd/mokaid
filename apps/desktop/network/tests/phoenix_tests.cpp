#include <mokaid/network/phoenix_client.hpp>
#include <QJsonArray>
#include <QJsonDocument>
#include <QPointer>
#include <QSignalSpy>
#include <QUrlQuery>
#include <QWebSocketServer>
#include <QtTest>
using namespace mokaid::desktop;
namespace {
class ChannelServer final : public QObject {
public:
    QWebSocketServer server{"Phoenix contract fixture", QWebSocketServer::NonSecureMode};
    QPointer<QWebSocket> peer;
    QHash<QString, QString> joins;
    QNetworkRequest handshake;
    int connections{};
    bool approve{true};
    ChannelServer() {
        server.listen(QHostAddress::LocalHost, 0);
        connect(&server, &QWebSocketServer::newConnection, this, [this] {
            peer = server.nextPendingConnection(); peer->setParent(this);
            handshake = peer->request(); ++connections; joins.clear();
            connect(peer, &QWebSocket::disconnected, peer, &QObject::deleteLater);
            connect(peer, &QWebSocket::textMessageReceived, this, [this](const QString& text) {
                const auto frame = QJsonDocument::fromJson(text.toUtf8()).array();
                if (frame.size() != 5) return;
                if (frame[3] == "phx_join") {
                    joins[frame[2].toString()] = frame[1].toString();
                    if (approve) acknowledge(frame[2].toString());
                }
            });
        });
    }
    QUrl origin() const { return QUrl(QString("http://127.0.0.1:%1").arg(server.serverPort())); }
    void send(const QJsonArray& frame) { peer->sendTextMessage(QString::fromUtf8(QJsonDocument(frame).toJson(QJsonDocument::Compact))); }
    void acknowledge(const QString& topic, const QString& status = "ok") {
        const auto ref = joins.value(topic);
        send({ref, ref, topic, "phx_reply", QJsonObject{{"status", status}, {"response", QJsonObject{}}}});
    }
};
}
class PhoenixTests final : public QObject {
    Q_OBJECT
private slots:
    void joinsScopeReferencesAndCredentials() {
        ChannelServer remote; QVERIFY(remote.server.isListening()); remote.approve = false;
        PhoenixClient client; QSignalSpy ready(&client, &PhoenixClient::rejoined), events(&client, &PhoenixClient::eventReceived);
        client.start(remote.origin(), "fixture-secret", "workspace-a", "alice");
        QTRY_COMPARE(remote.joins.size(), 2);
        QCOMPARE(remote.handshake.rawHeader("X-Mokaid-Authorization"), QByteArray("Bearer fixture-secret"));
        QCOMPARE(QUrlQuery(remote.handshake.url()).queryItems().size(), 1);
        QVERIFY(!remote.handshake.url().toString().contains("fixture-secret"));
        const auto topic = QString("workspace:workspace-a"), ref = remote.joins.value(topic);
        remote.send({ref, QJsonValue::Null, topic, "agent.updated", QJsonObject{}});
        remote.send({"stale", ref, topic, "phx_reply", QJsonObject{{"status", "ok"}}});
        QTest::qWait(50); QCOMPARE(events.size(), 0); QCOMPARE(ready.size(), 0);
        remote.acknowledge(topic); QTest::qWait(50); QCOMPARE(ready.size(), 0);
        remote.acknowledge("notifications:alice"); QTRY_COMPARE(ready.size(), 1);
        remote.send({"old", QJsonValue::Null, topic, "agent.updated", QJsonObject{}});
        remote.send({QJsonValue::Null, QJsonValue::Null, "workspace:other", "agent.updated", QJsonObject{}});
        remote.send({ref, QJsonValue::Null, topic, "agent.updated", QJsonObject{{"id", "actual"}}});
        QTRY_COMPARE(events.size(), 1); QCOMPARE(events.first()[2].toJsonObject().value("id").toString(), QString("actual"));
        client.stop();
    }
    void reconnectRejoinsAndLogoutDoesNotReconnect() {
        ChannelServer remote; QVERIFY(remote.server.isListening());
        PhoenixClient client; QSignalSpy ready(&client, &PhoenixClient::rejoined), expired(&client, &PhoenixClient::authenticationExpired);
        client.start(remote.origin(), "fixture-secret", "workspace-a", "alice"); QTRY_COMPARE(ready.size(), 1);
        const auto previous = remote.joins;
        remote.peer->close(); QTRY_COMPARE_WITH_TIMEOUT(ready.size(), 2, 4000);
        QCOMPARE(remote.connections, 2); QVERIFY(remote.joins != previous);
        remote.send({QJsonValue::Null, QJsonValue::Null, "phoenix", "disconnect", QJsonObject{}});
        QTRY_COMPARE(expired.size(), 1); QTest::qWait(900); QCOMPARE(remote.connections, 2);
    }
    void rejectedJoinDoesNotDeliverData() {
        ChannelServer remote; QVERIFY(remote.server.isListening()); remote.approve = false;
        PhoenixClient client; QSignalSpy expired(&client, &PhoenixClient::authenticationExpired), events(&client, &PhoenixClient::eventReceived);
        client.start(remote.origin(), "fixture-secret", "workspace-a", "alice"); QTRY_COMPARE(remote.joins.size(), 2);
        remote.acknowledge("workspace:workspace-a", "error"); QTRY_COMPARE(expired.size(), 1);
        QTest::qWait(900); QCOMPARE(remote.connections, 1); QCOMPARE(events.size(), 0);
    }
};
QTEST_GUILESS_MAIN(PhoenixTests)
#include "phoenix_tests.moc"
