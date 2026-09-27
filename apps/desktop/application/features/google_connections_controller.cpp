#include <mokaid/features/google_connections_controller.hpp>
#include <QDateTime>
#include <QJsonArray>
#include <QRegularExpression>

namespace mokaid::desktop {
namespace {
QString flowPath(const QString& id) { return "/api/integrations/google/desktop/" + QString::fromLatin1(QUrl::toPercentEncoding(id)); }
QString connectionError(const QString& code) {
    if (code == "authorization_expired") return "Google sign-in expired. Choose the service again to open a new sign-in window.";
    if (code == "authorization_cancelled") return "Google sign-in was cancelled. Connect again when you are ready.";
    if (code == "integration_permission_required" || code == "mail_permission_required" || code == "permission_required" || code == "service_permission_required")
        return "Allow access to the selected Google service when Google asks, then try again.";
    if (code == "provider_unavailable" || code == "oauth_not_configured") return "This Google service is temporarily unavailable. Contact your Mokaid administrator, then try again.";
    if (code == "provider_disabled") return "This Google service is disabled in Mokaid. Ask your administrator to enable it, then try again.";
    if (code == "reconnect_with_consent") return "Connect again and allow the requested access so your service remains available when you are away.";
    if (code == "workspace_access_revoked") return "Your workspace access changed. Sign in again before connecting Google.";
    if (code == "google_account_unverified") return "Verify this email address with Google before connecting it.";
    return "Google could not complete the connection. Check the message in your browser, then try again.";
}
}
GoogleConnectionsController::GoogleConnectionsController(ApiClient& api, SessionController& session, QObject* parent)
    : QObject(parent), api_(api), poll_(this), contextGeneration_(api.context().generation) {
    poll_.setInterval(2500);
    connect(&poll_, &QTimer::timeout, this, &GoogleConnectionsController::check);
    connect(&session, &SessionController::changed, this, &GoogleConnectionsController::syncContext);
    connect(&session, &SessionController::workspaceChanged, this, &GoogleConnectionsController::syncContext);
    connect(&session, &SessionController::cleared, this, &GoogleConnectionsController::syncContext);
    connect(&api, &ApiClient::onlineChanged, this, [this] {
        syncContext(); emit changed();
        if (online()) { if (active_) refresh(); check(); }
    });
}
GoogleConnectionsController::~GoogleConnectionsController() {
    for (auto* owner : {&listOwner_, &submitOwner_, &pollOwner_}) api_.cancelRequests(owner);
}
QVariantList GoogleConnectionsController::services() const {
    return {
        QVariantMap{{"key","gmail"},{"name","Gmail"},{"description","Connect a mailbox and synchronize its messages."},{"icon","mail"}},
        QVariantMap{{"key","google_calendar"},{"name","Google Calendar"},{"description","Read your Google calendars and events."},{"icon","calendar"}},
        QVariantMap{{"key","google_drive"},{"name","Google Drive"},{"description","Read your Google Drive files."},{"icon","folder"}},
        QVariantMap{{"key","google_docs"},{"name","Google Docs"},{"description","Read your Google documents."},{"icon","file"}},
        QVariantMap{{"key","google_sheets"},{"name","Google Sheets"},{"description","Read your Google spreadsheets."},{"icon","analytics"}},
        QVariantMap{{"key","google_meet"},{"name","Google Meet"},{"description","Read Google Meet meeting details."},{"icon","members"}}
    };
}
bool GoogleConnectionsController::supported(const QString& key) const {
    for (const auto& value : services()) if (value.toMap().value("key").toString() == key) return true;
    return false;
}
QString GoogleConnectionsController::providerName() const {
    for (const auto& value : services()) if (value.toMap().value("key").toString() == providerKey_) return value.toMap().value("name").toString();
    return "Google";
}
void GoogleConnectionsController::syncContext() {
    if (contextGeneration_ == api_.context().generation) return;
    contextGeneration_ = api_.context().generation; ++epoch_;
    for (auto* owner : {&listOwner_, &submitOwner_, &pollOwner_}) api_.cancelRequests(owner);
    poll_.stop(); connections_.clear(); providerKey_.clear(); flowId_.clear(); authorizeUrl_.clear();
    error_.clear(); message_.clear(); needsAttention_ = false; refreshing_ = submitting_ = polling_ = false;
    emit contextReset(); emit changed();
}
void GoogleConnectionsController::fail(const QString& message) { error_ = message; emit changed(); }
bool GoogleConnectionsController::available() {
    syncContext();
    if (online()) return true;
    fail("Connect to your workspace to manage Google services."); return false;
}
void GoogleConnectionsController::setActive(bool active) { syncContext(); active_ = active; if (active && online()) refresh(); }
void GoogleConnectionsController::refresh() {
    if (!available() || refreshing_) return;
    refreshing_ = true; emit changed();
    const auto epoch = epoch_;
    api_.request("GET", "/api/integrations", {}, core::Scope::workspace, &listOwner_, [this, epoch](ApiResponse response) {
        if (epoch != epoch_ || contextGeneration_ != api_.context().generation) return;
        refreshing_ = false;
        if (!response.ok()) { fail(response.error); return; }
        QVariantList rows;
        for (const auto& value : response.json.value("data").toObject().value("connections").toArray()) {
            const auto raw = value.toObject();
            if (!supported(raw.value("provider_key").toString())) continue;
            QVariantMap safe;
            for (const auto* key : {"id", "provider_key", "provider_name", "status", "connected_account", "last_sync_at"})
                if (raw.contains(key)) safe.insert(key, raw.value(key).toVariant());
            rows.append(safe);
        }
        connections_ = rows; emit changed();
    });
}
void GoogleConnectionsController::start(const QString& providerKey) {
    if (!available() || submitting_ || pending()) return;
    if (!supported(providerKey)) { fail("Choose a supported Google service."); return; }
    providerKey_ = providerKey; error_.clear(); message_.clear(); needsAttention_ = false; submitting_ = true; emit changed();
    const auto epoch = epoch_;
    api_.request("POST", "/api/integrations/google/desktop/start", {{"provider_key",providerKey}}, core::Scope::workspace, &submitOwner_, [this, epoch](ApiResponse response) {
        if (epoch != epoch_ || contextGeneration_ != api_.context().generation) return;
        submitting_ = false;
        if (!response.ok()) {
            const auto problem = response.json.value("error");
            const auto code = problem.isString() ? problem.toString() : problem.toObject().value("code").toString();
            fail(code.isEmpty() ? response.error : connectionError(code)); return;
        }
        const auto data = response.json.value("data").toObject();
        const QUrl url(data.value("authorize_url").toString()); const auto id = data.value("flow_id").toString();
        if (!url.isValid() || url.scheme() != "https" || url.host() != "accounts.google.com" || !url.userInfo().isEmpty() ||
            url.port(443) != 443 || url.path() != "/o/oauth2/v2/auth" || url.hasFragment() ||
            !QRegularExpression("^[A-Za-z0-9_-]{1,256}$").match(id).hasMatch()) {
            fail("The Google sign-in link was incomplete. Choose the service again to retry."); return;
        }
        authorizeUrl_ = url; flowId_ = id; deadline_ = QDateTime::currentMSecsSinceEpoch() + 10 * 60 * 1000;
        poll_.start(); emit changed(); emit requestExternal(url);
    });
}
void GoogleConnectionsController::check() {
    syncContext();
    if (!pending() || polling_ || submitting_ || !online()) return;
    if (QDateTime::currentMSecsSinceEpoch() >= deadline_) { clearFlow(); fail(connectionError("authorization_expired")); return; }
    polling_ = true; const auto epoch = epoch_; const auto id = flowId_;
    api_.request("GET", flowPath(id), {}, core::Scope::workspace, &pollOwner_, [this, epoch, id](ApiResponse response) {
        if (epoch != epoch_ || contextGeneration_ != api_.context().generation || id != flowId_) return;
        polling_ = false;
        if (!response.ok()) {
            if (response.status == 404 || response.status == 410) { clearFlow(); fail(connectionError("authorization_expired")); }
            else fail(response.networkError ? "Waiting for the connection to return. Google sign-in will be checked again automatically." : response.error);
            return;
        }
        const auto data = response.json.value("data").toObject(); const auto status = data.value("status").toString();
        if (status == "connected") acceptCompletion(data);
        else if (status == "failed") { clearFlow(); fail(connectionError(data.value("error").toString())); }
        else { error_.clear(); emit changed(); }
    });
}
void GoogleConnectionsController::cancel() {
    if (!available() || !pending() || submitting_) return;
    poll_.stop(); api_.cancelRequests(&pollOwner_); polling_ = false; submitting_ = true; error_.clear(); emit changed();
    const auto epoch = epoch_; const auto id = flowId_;
    api_.request("DELETE", flowPath(id), {}, core::Scope::workspace, &pollOwner_, [this, epoch, id](ApiResponse response) {
        if (epoch != epoch_ || contextGeneration_ != api_.context().generation || id != flowId_) return;
        submitting_ = false;
        if (!response.ok()) { poll_.start(); fail("Sign-in could not be cancelled yet. Keep this window open while we check the connection, or try Cancel again."); return; }
        const auto data = response.json.value("data").toObject(); const auto status = data.value("status").toString();
        if (status == "connected") acceptCompletion(data);
        else if (status == "failed") { clearFlow(); error_.clear(); emit changed(); emit cancelled(); }
        else { poll_.start(); fail("Google sign-in is still pending. Try Cancel again."); }
    });
}
void GoogleConnectionsController::acceptCompletion(const QJsonObject& data) {
    const auto service = providerKey_;
    if (data.value("provider_key").toString() != service || data.value("connection_id").toString().isEmpty() || data.value("connected_account").toString().isEmpty()) {
        clearFlow(); refresh(); fail("The server did not confirm the requested Google connection. Refresh the connected accounts before trying again."); return;
    }
    const auto label = providerName(); clearFlow(); error_.clear();
    message_ = label + " connected to " + data.value("connected_account").toString() + ".";
    const auto toolStatus = data.value("mcp_status").toString();
    needsAttention_ = toolStatus == "different_account" || toolStatus == "unavailable";
    if (toolStatus == "different_account") message_ += " Agent tools currently use " + data.value("mcp_connected_account").toString() + ".";
    else if (toolStatus == "unavailable") message_ += " Authorization is saved; check the service setup in Integrations to enable agent tools.";
    refresh(); emit changed(); emit connected(service);
}
void GoogleConnectionsController::clearFlow() {
    poll_.stop(); api_.cancelRequests(&pollOwner_); flowId_.clear(); authorizeUrl_.clear(); polling_ = false; emit changed();
}
void GoogleConnectionsController::reopenBrowser() { if (pending() && !submitting_ && !authorizeUrl_.isEmpty()) emit requestExternal(authorizeUrl_); }
void GoogleConnectionsController::clearFeedback() { error_.clear(); message_.clear(); needsAttention_ = false; emit changed(); }
}
