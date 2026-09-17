#include <mokaid/application/session_controller.hpp>
#include <QCryptographicHash>
#include <QDesktopServices>
#include <QJsonDocument>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QPointer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QUrlQuery>
#include <QtTest>

using namespace mokaid::desktop;
namespace {
struct Request { QString path; QJsonObject body; QByteArray headers; };
class MemoryCredentials final : public CredentialStorage {
public:
    mutable QByteArray value;
    mutable int reads{}, writes{}, erases{};
    bool writable{true}, erasable{true};
    std::optional<QByteArray> read(const QString&) const override { ++reads; return value; }
    bool write(const QString&, const QByteArray& next) const override {
        ++writes; if (!writable) return false; value = next; return true;
    }
    bool erase(const QString&) const override { ++erases; if (!erasable) return false; value.clear(); return true; }
};
class SessionApi final : public QObject {
public:
    QTcpServer server;
    QList<Request> requests;
    std::function<bool(QTcpSocket*, const Request&)> handler;
    SessionApi() {
        if (!server.listen(QHostAddress::LocalHost, 0)) qFatal("Session tests require permission to bind a temporary loopback port");
        connect(&server, &QTcpServer::newConnection, this, [this] {
            while (server.hasPendingConnections()) {
                auto* socket = server.nextPendingConnection();
                connect(socket, &QTcpSocket::disconnected, socket, &QObject::deleteLater);
                connect(socket, &QTcpSocket::readyRead, this, [this, socket] {
                    auto bytes = socket->property("request").toByteArray() + socket->readAll();
                    socket->setProperty("request", bytes);
                    const auto end = bytes.indexOf("\r\n\r\n");
                    if (end < 0 || socket->property("handled").toBool()) return;
                    qsizetype length = 0;
                    for (const auto& line : bytes.left(end).split('\n'))
                        if (line.toLower().startsWith("content-length:")) length = line.mid(15).trimmed().toLongLong();
                    if (bytes.size() < end + 4 + length) return;
                    socket->setProperty("handled", true);
                    const auto path = bytes.left(bytes.indexOf("\r\n")).split(' ').value(1);
                    Request request{QString::fromUtf8(path), QJsonDocument::fromJson(bytes.mid(end + 4, length)).object(), bytes.left(end)};
                    requests.append(request);
                    if (handler && handler(socket, request)) return;
                    if (request.path == "/api/desktop/auth/requests") reply(socket, {{"data", QJsonObject{
                        {"authorization_url", "https://mokaid.test/desktop/authorize?request_id=ababcabc-0000-4000-8000-000000000001"}}}}, 201);
                    else if (request.path == "/api/desktop/auth/token") reply(socket, tokens());
                    else if (request.path == "/api/me") reply(socket, {{"user", QJsonObject{{"id", "alice"}, {"is_platform_admin", false}}},
                        {"workspaces", QJsonArray{QJsonObject{{"id", "workspace-a"}}}}});
                    else reply(socket, {}, request.path == "/api/desktop/auth/revoke" ? 204 : 404);
                });
            }
        });
    }
    QUrl origin() const { return QUrl(QString("http://127.0.0.1:%1").arg(server.serverPort())); }
    QList<Request> matching(const QString& path) const {
        QList<Request> found;
        for (const auto& request : requests) if (request.path == path) found.append(request);
        return found;
    }
    static QJsonObject tokens() {
        return {{"data", QJsonObject{{"access_token", "fixture-access"}, {"refresh_token", "fixture-refresh-next"},
            {"expires_in", 600}, {"token_type", "Bearer"}, {"user", QJsonObject{{"id", "alice"}}}}}};
    }
    static void reply(QTcpSocket* socket, const QJsonObject& object, int status = 200) {
        const auto json = status == 204 ? QByteArray{} : QJsonDocument(object).toJson(QJsonDocument::Compact);
        socket->write("HTTP/1.1 " + QByteArray::number(status) + " Response\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: "
            + QByteArray::number(json.size()) + "\r\n\r\n" + json);
        socket->disconnectFromHost();
    }
};
struct Fixture {
    SessionApi remote;
    MemoryCredentials vault;
    ApiClient api{remote.origin()};
    PhoenixClient realtime;
    SessionController session{api, realtime, nullptr, QUrl("https://mokaid.test"), &vault};
};
}

class SessionTests final : public QObject {
    Q_OBJECT
    QTemporaryDir preferences_;
    QList<QUrl> browserUrls_;
public slots:
    void openBrowser(const QUrl& url) { browserUrls_.append(url); }
private:
    void callback(Fixture& f, const QString& state = {}) {
        const auto request = f.remote.matching("/api/desktop/auth/requests").last().body;
        QUrl url(request.value("redirect_uri").toString());
        QUrlQuery query; query.addQueryItem("code", "one-time-code");
        query.addQueryItem("state", state.isEmpty() ? request.value("state").toString() : state); url.setQuery(query);
        QNetworkAccessManager manager;
        auto* reply = manager.get(QNetworkRequest(url));
        QSignalSpy complete(reply, &QNetworkReply::finished);
        QTRY_COMPARE(complete.size(), 1);
        QCOMPARE(reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt(), state.isEmpty() ? 200 : 400);
        QCOMPARE(reply->rawHeader("Referrer-Policy"), QByteArray("no-referrer"));
    }
private slots:
    void initTestCase() {
        QVERIFY(preferences_.isValid());
        QCoreApplication::setOrganizationName("MokaidSessionTests");
        QCoreApplication::setOrganizationDomain("mokaid-session-tests.invalid");
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, preferences_.path());
        QDesktopServices::setUrlHandler("https", this, "openBrowser");
    }
    void cleanupTestCase() { QDesktopServices::unsetUrlHandler("https"); }
    void init() { browserUrls_.clear(); QSettings().clear(); }
    void browserHandoffBindsPkceAndStateAndStoresOnlyRefresh() {
        Fixture f; f.session.signIn();
        QTRY_COMPARE(browserUrls_.size(), 1);
        QCOMPARE(browserUrls_.first().query(), QString("request_id=ababcabc-0000-4000-8000-000000000001"));
        const auto initial = f.remote.matching("/api/desktop/auth/requests").first();
        QCOMPARE(initial.body.value("state").toString().size(), 43);
        QCOMPARE(initial.body.value("code_challenge").toString().size(), 43);
        callback(f, "wrong-state"); QCOMPARE(f.remote.matching("/api/desktop/auth/token").size(), 0);
        QVERIFY(f.session.busy()); callback(f);
        QTRY_VERIFY(f.session.authenticated()); QTRY_VERIFY(!f.session.busy());
        const auto exchange = f.remote.matching("/api/desktop/auth/token").first();
        const auto challenge = QCryptographicHash::hash(exchange.body.value("code_verifier").toString().toLatin1(), QCryptographicHash::Sha256)
            .toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals);
        QCOMPARE(challenge, initial.body.value("code_challenge").toString().toLatin1());
        QCOMPARE(exchange.body.value("redirect_uri"), initial.body.value("redirect_uri"));
        QVERIFY(!exchange.headers.contains("Authorization:"));
        QCOMPARE(f.vault.value, QByteArray("fixture-refresh-next"));
        QCOMPARE(f.api.accessToken(), QByteArray("fixture-access"));
        const auto preferences = QSettings().value(QSettings().allKeys().first()).toByteArray();
        QVERIFY(!preferences.contains("fixture-refresh")); QVERIFY(!preferences.contains("fixture-access"));
        QVERIFY(f.remote.matching("/api/me").first().headers.contains("Authorization: Bearer fixture-access"));
    }
    void cancellationRevokesAnExchangeThatAlreadyReachedTheServer() {
        Fixture f; QPointer<QTcpSocket> exchange;
        f.remote.handler = [&](QTcpSocket* socket, const Request& request) {
            if (request.path != "/api/desktop/auth/token") return false; exchange = socket; return true;
        };
        f.session.signIn(); QTRY_COMPARE(browserUrls_.size(), 1); callback(f); QTRY_VERIFY(exchange);
        f.session.cancelSignIn(); SessionApi::reply(exchange, SessionApi::tokens());
        QTRY_COMPARE(f.remote.matching("/api/desktop/auth/revoke").size(), 1);
        QVERIFY(!f.session.authenticated()); QVERIFY(f.vault.value.isEmpty()); QVERIFY(f.api.accessToken().isEmpty());
        QCOMPARE(f.remote.matching("/api/desktop/auth/revoke").first().body.value("refresh_token").toString(), QString("fixture-refresh-next"));
    }
    void renewalIsSerializedAndReplacesTheSavedCredential() {
        Fixture f; f.vault.value = "fixture-refresh-old"; QPointer<QTcpSocket> exchange;
        f.remote.handler = [&](QTcpSocket* socket, const Request& request) {
            if (request.path != "/api/desktop/auth/token") return false; exchange = socket; return true;
        };
        f.session.restore(); QTRY_VERIFY(exchange);
        emit f.api.sessionExpired(); emit f.api.sessionExpired(); emit f.realtime.authenticationExpired();
        QTest::qWait(30); QCOMPARE(f.remote.matching("/api/desktop/auth/token").size(), 1);
        SessionApi::reply(exchange, SessionApi::tokens()); QTRY_VERIFY(f.session.authenticated()); QTRY_VERIFY(!f.session.busy());
        QCOMPARE(f.vault.value, QByteArray("fixture-refresh-next")); QCOMPARE(f.vault.writes, 1);
    }
    void interruptedRotationRequiresNewSignIn_data() {
        QTest::addColumn<bool>("serverError");
        QTest::newRow("truncated-token-response") << false;
        QTest::newRow("server-error-after-possible-commit") << true;
    }
    void interruptedRotationRequiresNewSignIn() {
        QFETCH(bool, serverError);
        Fixture f; f.vault.value = "fixture-refresh-old";
        f.remote.handler = [&](QTcpSocket* socket, const Request& request) {
            if (request.path != "/api/desktop/auth/token") return false;
            if (serverError) { SessionApi::reply(socket, {{"error", "Unavailable"}}, 500); return true; }
            socket->write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 1000\r\nConnection: close\r\n\r\n{\"data\":");
            socket->disconnectFromHost(); return true;
        };
        f.session.restore(); QTRY_VERIFY(!f.session.busy());
        QVERIFY(f.vault.value.isEmpty()); QVERIFY(!f.session.authenticated());
        QVERIFY(f.session.error().contains("Sign in again"));
        QTRY_COMPARE(f.remote.matching("/api/desktop/auth/revoke").size(), 1);
        f.session.restore(); emit f.api.sessionExpired(); QTest::qWait(30);
        QCOMPARE(f.remote.matching("/api/desktop/auth/token").size(), 1);
    }
    void connectionRefusalRetainsTheUnspentCredentialForRetry() {
        Fixture f; f.vault.value = "fixture-refresh-old";
        const auto port = f.remote.server.serverPort(); f.remote.server.close();
        f.session.restore(); QTRY_VERIFY(!f.session.busy());
        QCOMPARE(f.vault.value, QByteArray("fixture-refresh-old")); QVERIFY(!f.session.online());
        QVERIFY(f.remote.server.listen(QHostAddress::LocalHost, port));
        f.session.retry(); QTRY_VERIFY(f.session.authenticated()); QTRY_VERIFY(!f.session.busy());
        QCOMPARE(f.vault.value, QByteArray("fixture-refresh-next")); QCOMPARE(f.remote.matching("/api/desktop/auth/token").size(), 1);
    }
    void shortLivedAccessCredentialsRenewBeforeTheyExpire() {
        Fixture f; f.vault.value = "fixture-refresh-old";
        f.remote.handler = [&](QTcpSocket* socket, const Request& request) {
            if (request.path != "/api/desktop/auth/token" || f.remote.matching(request.path).size() != 1) return false;
            auto tokens = SessionApi::tokens().value("data").toObject(); tokens["expires_in"] = 2;
            SessionApi::reply(socket, {{"data", tokens}}); return true;
        };
        f.session.restore(); QTRY_VERIFY(f.session.authenticated()); QTRY_VERIFY(!f.session.busy());
        QTRY_COMPARE_WITH_TIMEOUT(f.remote.matching("/api/desktop/auth/token").size(), 2, 4000);
        QTRY_VERIFY(!f.session.busy());
        QCOMPARE(f.remote.matching("/api/desktop/auth/token").last().body.value("refresh_token").toString(), QString("fixture-refresh-next"));
    }
    void rateLimitKeepsTheUnspentCredential() {
        Fixture f; f.vault.value = "fixture-refresh-old";
        f.remote.handler = [](QTcpSocket* socket, const Request& request) {
            if (request.path != "/api/desktop/auth/token") return false;
            SessionApi::reply(socket, {{"error", "Try later"}}, 429); return true;
        };
        f.session.restore(); QTRY_VERIFY(!f.session.busy()); QCOMPARE(f.vault.value, QByteArray("fixture-refresh-old"));
        f.remote.handler = {}; f.session.retry(); QTRY_VERIFY(f.session.authenticated());
        QCOMPARE(f.remote.matching("/api/desktop/auth/token").size(), 2);
    }
    void secureStorageFailureRevokesIssuedCredentialsAndClearsIdentity() {
        Fixture f; f.vault.value = "fixture-refresh-old"; f.vault.writable = false;
        f.session.restore(); QTRY_VERIFY(!f.session.busy());
        QVERIFY(!f.session.authenticated()); QVERIFY(f.api.accessToken().isEmpty()); QVERIFY(f.vault.value.isEmpty());
        QVERIFY(f.session.error().contains("securely save"));
        QTRY_COMPARE(f.remote.matching("/api/desktop/auth/revoke").size(), 2);
        QSet<QString> revoked;
        for (const auto& request : f.remote.matching("/api/desktop/auth/revoke")) revoked.insert(request.body.value("refresh_token").toString());
        QVERIFY(revoked.contains("fixture-refresh-old")); QVERIFY(revoked.contains("fixture-refresh-next"));
    }
    void invalidTokenResponsesFailClosed_data() {
        QTest::addColumn<QString>("field"); QTest::addColumn<QJsonValue>("value");
        QTest::newRow("expired") << QString("expires_in") << QJsonValue(0);
        QTest::newRow("overflow") << QString("expires_in") << QJsonValue(2147483647);
        QTest::newRow("missing-lifetime") << QString("expires_in") << QJsonValue();
        QTest::newRow("wrong-token-type") << QString("token_type") << QJsonValue("Basic");
        QTest::newRow("header-injection") << QString("access_token") << QJsonValue("unsafe\r\nInjected: value");
    }
    void invalidTokenResponsesFailClosed() {
        QFETCH(QString, field); QFETCH(QJsonValue, value);
        Fixture f; f.vault.value = "fixture-refresh-old";
        f.remote.handler = [&](QTcpSocket* socket, const Request& request) {
            if (request.path != "/api/desktop/auth/token") return false;
            auto tokens = SessionApi::tokens().value("data").toObject(); tokens[field] = value;
            SessionApi::reply(socket, {{"data", tokens}}); return true;
        };
        f.session.restore(); QTRY_VERIFY(!f.session.busy()); QVERIFY(!f.session.authenticated());
        QVERIFY(f.api.accessToken().isEmpty()); QVERIFY(f.vault.value.isEmpty()); QCOMPARE(f.vault.writes, 0);
        QVERIFY(f.remote.matching("/api/me").isEmpty());
    }
    void logoutDuringRenewalCannotRestoreTheSession() {
        Fixture f; f.vault.value = "fixture-refresh-old"; QPointer<QTcpSocket> exchange;
        f.remote.handler = [&](QTcpSocket* socket, const Request& request) {
            if (request.path != "/api/desktop/auth/token") return false; exchange = socket; return true;
        };
        f.session.restore(); QTRY_VERIFY(exchange); f.session.signOut();
        if (exchange && exchange->state() == QAbstractSocket::ConnectedState) SessionApi::reply(exchange, SessionApi::tokens());
        QTRY_COMPARE(f.remote.matching("/api/desktop/auth/revoke").size(), 1);
        QCOMPARE(f.remote.matching("/api/desktop/auth/revoke").first().body.value("refresh_token").toString(), QString("fixture-refresh-old"));
        QVERIFY(!f.session.authenticated()); QVERIFY(f.api.accessToken().isEmpty()); QVERIFY(f.vault.value.isEmpty());
    }
    void failedKeychainEraseCannotRestoreLoggedOutCredentials() {
        Fixture f; f.vault.value = "fixture-refresh-old";
        f.session.restore(); QTRY_VERIFY(f.session.authenticated()); QTRY_VERIFY(!f.session.busy());
        f.vault.erasable = false; f.session.signOut();
        QCOMPARE(f.vault.value, QByteArray("fixture-refresh-next"));
        SessionController restarted(f.api, f.realtime, nullptr, QUrl("https://mokaid.test"), &f.vault);
        const auto reads = f.vault.reads; restarted.restore();
        QCOMPARE(f.vault.reads, reads); QVERIFY(!restarted.authenticated()); QVERIFY(!restarted.busy());
    }
};
QTEST_GUILESS_MAIN(SessionTests)
#include "session_controller_tests.moc"
