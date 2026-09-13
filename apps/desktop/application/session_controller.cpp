#include <mokaid/application/session_controller.hpp>
#include <mokaid/application/authorization_policy.hpp>
#include <QCryptographicHash>
#include <QCoreApplication>
#include <QDesktopServices>
#include <QJsonDocument>
#include <QRandomGenerator>
#include <QTcpSocket>
#include <QUrlQuery>
#include <cstring>
#include <algorithm>
namespace mokaid::desktop {
namespace {
QByteArray randomUrlToken() {
    QByteArray bytes(32, '\0');
    for (qsizetype i = 0; i < bytes.size(); i += 4) {
        auto n = QRandomGenerator::system()->generate();
        std::memcpy(bytes.data() + i, &n, 4);
    }
    return bytes.toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals);
}
}
SessionController::SessionController(ApiClient& api, PhoenixClient& realtime, QObject* parent, QUrl trustedWebOrigin)
    : QObject(parent), api_(api), realtime_(realtime), browserOrigin_(trustedWebOrigin.isEmpty() ? api.origin() : std::move(trustedWebOrigin)),
      vault_(QCoreApplication::organizationDomain() + ".session") {
    if (!validBrowserOrigin(browserOrigin_)) qFatal("Invalid trusted Mokaid browser origin");
    expiration_.setSingleShot(true); loginTimeout_.setSingleShot(true);
    connectivity_.setInterval(15000);
    connect(&expiration_, &QTimer::timeout, this, &SessionController::renew);
    connect(&loginTimeout_, &QTimer::timeout, this, [this] { cancelSignIn(); fail("Sign-in expired. Please try again."); });
    connect(&callback_, &QTcpServer::newConnection, this, &SessionController::receiveCallback);
    connect(&api_, &ApiClient::sessionExpired, this, &SessionController::renew);
    connect(&api_, &ApiClient::administratorDenied, this, [this] { user_["is_platform_admin"] = false; emit changed(); });
    connect(&api_, &ApiClient::onlineChanged, this, [this](bool connected) {
        if (!connected) realtime_.stop();
        else QTimer::singleShot(0, this, [this] {
            if (authenticated_ && online() && !refreshing_ && !busy_) reloadIdentity();
        });
        emit changed();
    });
    connect(&realtime_, &PhoenixClient::authenticationExpired, this, &SessionController::renew);
    connect(&connectivity_, &QTimer::timeout, this, [this] {
        // Recovery may renew a saved session, never start browser sign-in without a user action.
        if (!online() && !busy_ && !refreshing_ && !refreshToken_.isEmpty()) renew();
    });
    connectivity_.start();
}
QString SessionController::identityKey() const {
    return QString::fromLatin1(QCryptographicHash::hash(api_.origin().toEncoded(), QCryptographicHash::Sha256).toHex());
}
void SessionController::restore() {
    const auto saved = vault_.read(identityKey());
    if (!saved || saved->isEmpty()) return;
    refreshToken_ = *saved;
    const auto stored = QJsonDocument::fromJson(settings_.value(identityKey() + "/identity").toByteArray()).object();
    user_ = stored.value("user").toObject(); user_["is_platform_admin"] = false;
    workspaces_ = stored.value("workspaces").toArray(); workspace_ = stored.value("workspace").toString();
    authenticated_ = !user_.value("id").toString().isEmpty();
    renew();
}
void SessionController::fail(const QString& message) { busy_ = false; error_ = message; emit changed(); }
void SessionController::signIn() {
    cancelSignIn(); error_.clear();
    if (!callback_.listen(QHostAddress::LocalHost, 0)) { fail("Unable to open the local sign-in callback."); return; }
    verifier_ = randomUrlToken(); state_ = QString::fromLatin1(randomUrlToken());
    redirect_ = QString("http://127.0.0.1:%1/callback").arg(callback_.serverPort());
    const auto challenge = QCryptographicHash::hash(verifier_, QCryptographicHash::Sha256).toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals);
    busy_ = true; emit changed(); loginTimeout_.start(5 * 60 * 1000);
    const auto transaction = state_;
    api_.request("POST", "/api/desktop/auth/requests", {{"code_challenge", QString::fromLatin1(challenge)}, {"redirect_uri", redirect_}, {"state", state_}}, core::Scope::public_api, this, [this, transaction](ApiResponse r) {
        if (state_ != transaction || !callback_.isListening()) return;
        if (!r.ok()) {
            callback_.close(); loginTimeout_.stop();
            fail(r.status == 404 ? "Desktop sign-in is not enabled on this server yet. Deploy the desktop authentication endpoints, then try again." : r.error);
            return;
        }
        const QUrl url(r.json.value("data").toObject().value("authorization_url").toString());
        if (!allowedAuthorizationUrl(browserOrigin_, url)) {
            cancelSignIn(); fail("The server returned an invalid authorization address."); return;
        }
        if (!QDesktopServices::openUrl(url)) { cancelSignIn(); fail("Unable to open your browser."); }
    });
}
void SessionController::cancelSignIn() {
    ++loginGeneration_;
    callback_.close(); loginTimeout_.stop(); verifier_.fill('\0'); verifier_.clear(); state_.clear(); busy_ = false; emit changed();
}
void SessionController::receiveCallback() {
    while (callback_.hasPendingConnections()) {
        auto* socket = callback_.nextPendingConnection();
        connect(socket, &QTcpSocket::disconnected, socket, &QObject::deleteLater);
        QTimer::singleShot(5000, socket, [socket] { socket->disconnectFromHost(); });
        connect(socket, &QTcpSocket::readyRead, this, [this, socket] {
            auto buffer = socket->property("request").toByteArray() + socket->readAll();
            if (buffer.size() > 8192) { socket->disconnectFromHost(); return; }
            socket->setProperty("request", buffer);
            if (!buffer.contains("\r\n\r\n") || socket->property("handled").toBool()) return;
            socket->setProperty("handled", true);
            const auto parts = buffer.left(buffer.indexOf("\r\n")).split(' ');
            const QUrl url(parts.size() > 1 ? QString::fromLatin1(parts[1]) : QString{});
            const QUrlQuery query(url);
            const auto code = query.queryItemValue("code");
            const bool valid = allowedLoopbackRequest(buffer, QUrl(redirect_), state_) && !verifier_.isEmpty();
            const QByteArray body = valid ? "Authorization received. Return to Mokaid to finish signing in." : "Invalid sign-in callback.";
            socket->write((valid ? QByteArray("HTTP/1.1 200 OK\r\n") : QByteArray("HTTP/1.1 400 Bad Request\r\n"))
                + "Content-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: "
                + QByteArray::number(body.size()) + "\r\n\r\n" + body);
            socket->disconnectFromHost();
            if (!valid) return;
            callback_.close(); loginTimeout_.stop();
            const auto verifier = verifier_; verifier_.fill('\0'); verifier_.clear(); state_.clear();
            const auto login = loginGeneration_;
            api_.request("POST", "/api/desktop/auth/token", {{"grant_type", "authorization_code"}, {"code", code},
                {"code_verifier", QString::fromLatin1(verifier)}, {"redirect_uri", redirect_}}, core::Scope::public_api, this,
                [this, login](ApiResponse r) {
                    if (login != loginGeneration_) {
                        const auto discarded = r.json.value("data").toObject().value("refresh_token").toString();
                        if (!discarded.isEmpty()) api_.request("POST", "/api/desktop/auth/revoke", {{"refresh_token", discarded}}, core::Scope::public_api, this, [](ApiResponse) {});
                        return;
                    }
                    acceptTokens(r);
                });
        });
    }
}
void SessionController::acceptTokens(const ApiResponse& response) {
    refreshing_ = false;
    if (!response.ok()) {
        if (!response.networkError && (response.status == 400 || response.status == 401 || response.status == 403)) {
            signOut(); fail("Your session has expired. Sign in again.");
        } else fail(response.error);
        return;
    }
    const auto payload = response.json.value("data").toObject();
    const auto token = payload.value("access_token").toString().toUtf8();
    const auto refresh = payload.value("refresh_token").toString().toUtf8();
    const auto user = payload.value("user").toObject();
    if (token.isEmpty() || refresh.isEmpty() || user.value("id").toString().isEmpty()) { fail("Invalid session response."); return; }
    refreshToken_ = refresh;
    if (!vault_.write(identityKey(), refresh)) { fail("Your operating system could not securely save this session. Please try again."); return; }
    user_ = user;
    api_.setSession(token, user.value("id").toString(), user.value("is_platform_admin").toBool());
    authenticated_ = true; error_.clear();
    expiration_.start(std::max(30, payload.value("expires_in").toInt(600) - 60) * 1000);
    reloadIdentity();
}
void SessionController::renew() {
    if (refreshing_ || refreshToken_.isEmpty()) { if (refreshToken_.isEmpty()) signOut(); return; }
    refreshing_ = true; busy_ = true; emit changed();
    api_.request("POST", "/api/desktop/auth/token", {{"grant_type", "refresh_token"}, {"refresh_token", QString::fromUtf8(refreshToken_)}}, core::Scope::public_api, this,
        [this](ApiResponse r) { acceptTokens(r); });
}
void SessionController::reloadIdentity() {
    if (identityLoading_ || refreshing_) return;
    identityLoading_ = true; busy_ = true; emit changed();
    api_.request("GET", "/api/me", {}, core::Scope::identity, this, [this](ApiResponse r) {
        identityLoading_ = false;
        if (!r.ok()) { fail(r.error); return; }
        if (r.json.value("user").toObject().value("id").toString().isEmpty() || !r.json.value("workspaces").isArray()) {
            fail("The server returned an invalid workspace session. Please reconnect."); return;
        }
        user_ = r.json.value("user").toObject(); workspaces_ = r.json.value("workspaces").toArray();
        bool member = false;
        for (const auto& w : workspaces_) if (w.toObject().value("id").toString() == workspace_) member = true;
        if (!member) workspace_ = workspaces_.isEmpty() ? QString{} : workspaces_.first().toObject().value("id").toString();
        api_.setSession(api_.accessToken(), user_.value("id").toString(), user_.value("is_platform_admin").toBool());
        api_.setWorkspace(workspace_); persistIdentity();
        realtime_.start(api_.origin(), api_.accessToken(), workspace_, user_.value("id").toString());
        busy_ = false; error_.clear(); emit changed(); emit established();
    });
}
void SessionController::persistIdentity() {
    auto safeUser = user_; safeUser.remove("is_platform_admin"); safeUser.remove("operator_notes");
    settings_.setValue(identityKey() + "/identity", QJsonDocument(QJsonObject{{"user", safeUser}, {"workspaces", workspaces_}, {"workspace", workspace_}}).toJson(QJsonDocument::Compact));
}
void SessionController::selectWorkspace(const QString& id) {
    // Workspace changes cancel old-scoped requests, including session refresh.
    // Never discard a rotating refresh response or a membership verification.
    if (busy_ || refreshing_ || identityLoading_) return;
    if (id == workspace_) return;
    bool member = false;
    for (const auto& w : workspaces_) if (w.toObject().value("id").toString() == id) member = true;
    if (!member) return;
    workspace_ = id; api_.setWorkspace(id); persistIdentity();
    if (online()) realtime_.start(api_.origin(), api_.accessToken(), id, user_.value("id").toString());
    emit workspaceChanged(); emit changed();
}
void SessionController::retry() { if (!refreshToken_.isEmpty()) renew(); else signIn(); }
void SessionController::signOut() {
    expiration_.stop(); cancelSignIn(); realtime_.stop();
    const auto oldRefresh = refreshToken_;
    api_.reset(); refreshToken_.fill('\0'); refreshToken_.clear();
    static_cast<void>(vault_.erase(identityKey())); settings_.remove(identityKey() + "/identity");
    user_ = {}; workspaces_ = {}; workspace_.clear(); authenticated_ = false; refreshing_ = false; busy_ = false; identityLoading_ = false;
    emit cleared(); emit changed();
    if (!oldRefresh.isEmpty()) api_.request("POST", "/api/desktop/auth/revoke", {{"refresh_token", QString::fromUtf8(oldRefresh)}}, core::Scope::public_api, this, [](ApiResponse) {});
}
}
