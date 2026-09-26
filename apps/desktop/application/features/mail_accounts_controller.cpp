#include <mokaid/features/mail_accounts_controller.hpp>
#include <QDateTime>
#include <QJsonArray>
#include <QRegularExpression>

namespace mokaid::desktop {
namespace {
QString oauthError(const QString& code) {
    if (code == "authorization_expired") return "Google sign-in expired. Connect Gmail again.";
    if (code == "authorization_cancelled") return "Google sign-in was cancelled. Connect Gmail when you are ready.";
    if (code == "mail_permission_required") return "Allow access to Gmail when Google asks, so Mokaid can synchronize your inbox.";
    if (code == "reconnect_with_consent") return "Connect Gmail again and allow access so synchronization can continue when you are away.";
    if (code == "workspace_access_revoked") return "Your workspace access changed. Sign in again before connecting this mailbox.";
    if (code == "google_account_unverified") return "Verify this email address with Google before connecting it.";
    return "Google could not connect this mailbox. Please try signing in again.";
}
QString pathId(const QString& id) { return QString::fromLatin1(QUrl::toPercentEncoding(id)); }
QVariantMap safeAccount(const QVariantMap& source) {
    QVariantMap result, settings;
    for (const auto* key : {"id", "provider", "email_address", "display_name", "status", "error_message", "last_sync_at", "owner_name"})
        if (source.contains(key)) result.insert(key, source.value(key));
    const auto raw = source.value("settings").toMap();
    for (const auto* key : {"imap_host", "imap_port", "imap_security", "imap_ssl", "smtp_host", "smtp_port", "smtp_security", "smtp_ssl", "username", "smtp_username"})
        if (raw.contains(key)) settings.insert(key, raw.value(key));
    result.insert("settings", settings);
    return result;
}
}
MailAccountsController::MailAccountsController(ApiClient& api, SessionController& session, QObject* parent)
    : QObject(parent), api_(api), poll_(this), syncPoll_(this), contextGeneration_(api.context().generation) {
    poll_.setInterval(2500);
    syncPoll_.setInterval(5000);
    connect(&poll_, &QTimer::timeout, this, &MailAccountsController::checkOAuth);
    connect(&syncPoll_, &QTimer::timeout, this, [this] {
        if (QDateTime::currentMSecsSinceEpoch() >= syncDeadline_) {
            syncPoll_.stop(); awaitingSync_.clear(); message_ = "Synchronization continues in the background. Refresh to check for new mail."; emit changed(); return;
        }
        if (active_ && online()) { refresh(); emit messagesChanged(); }
    });
    connect(&session, &SessionController::changed, this, &MailAccountsController::syncContext);
    connect(&session, &SessionController::workspaceChanged, this, &MailAccountsController::syncContext);
    connect(&session, &SessionController::cleared, this, &MailAccountsController::syncContext);
    connect(&api, &ApiClient::onlineChanged, this, [this] {
        syncContext(); emit changed();
        if (online() && active_) { refresh(); checkOAuth(); }
    });
}
MailAccountsController::~MailAccountsController() {
    for (auto* owner : {&listOwner_, &submitOwner_, &oauthOwner_, &syncOwner_}) api_.cancelRequests(owner);
}
void MailAccountsController::syncContext() {
    if (contextGeneration_ == api_.context().generation) return;
    contextGeneration_ = api_.context().generation; ++epoch_;
    for (auto* owner : {&listOwner_, &submitOwner_, &oauthOwner_, &syncOwner_}) api_.cancelRequests(owner);
    poll_.stop(); syncPoll_.stop(); accounts_.clear(); selectedId_.clear(); flowId_.clear(); authorizeUrl_.clear();
    error_.clear(); message_.clear(); awaitingSync_.clear(); refreshing_ = submitting_ = syncing_ = polling_ = false; syncRequests_ = 0;
    emit contextReset(); emit changed();
}
void MailAccountsController::fail(const QString& message) { error_ = message; emit changed(); }
bool MailAccountsController::available() {
    syncContext();
    if (core::mayRequest(api_.context(), core::Scope::workspace, true)) return true;
    fail("Connect to your workspace to manage mailboxes."); return false;
}
bool MailAccountsController::knownAccount(const QString& id) const {
    for (const auto& value : accounts_) if (value.toMap().value("id").toString() == id) return true;
    return false;
}
QVariantMap MailAccountsController::selectedAccount() const {
    for (const auto& value : accounts_) if (value.toMap().value("id").toString() == selectedId_) return value.toMap();
    return {};
}
void MailAccountsController::setActive(bool active) {
    syncContext(); active_ = active;
    if (active && online()) refresh();
}
void MailAccountsController::refresh() {
    if (!available() || refreshing_) return;
    refreshing_ = true; emit changed();
    const auto epoch = epoch_;
    api_.request("GET", "/api/mail/accounts", {}, core::Scope::workspace, &listOwner_, [this, epoch](ApiResponse response) {
        if (epoch != epoch_ || contextGeneration_ != api_.context().generation) return;
        refreshing_ = false;
        if (!response.ok()) { fail(response.error); return; }
        QVariantList accounts;
        for (const auto& value : response.json.value("data").toArray()) accounts.append(safeAccount(value.toObject().toVariantMap()));
        accounts_ = accounts;
        if (syncPoll_.isActive() && !awaitingSync_.isEmpty()) {
            for (const auto& value : accounts_) {
                const auto account = value.toMap(); const auto id = account.value("id").toString();
                if (!awaitingSync_.contains(id)) continue;
                const auto date = QDateTime::fromString(account.value("last_sync_at").toString(), Qt::ISODateWithMs);
                if (account.value("status").toString() == "active" && date.isValid() && date.toMSecsSinceEpoch() >= syncDeadline_ - 2 * 60 * 1000 - 1000) awaitingSync_.remove(id);
            }
            if (awaitingSync_.isEmpty()) {
                syncPoll_.stop(); message_ = "Mail synchronized.";
                emit messagesChanged();
            }
        }
        if (!selectedId_.isEmpty() && !knownAccount(selectedId_)) { selectedId_.clear(); emit selectionChanged(); }
        emit changed();
    });
}
void MailAccountsController::select(const QString& id) {
    syncContext();
    if (selectedId_ == id || (!id.isEmpty() && !knownAccount(id))) return;
    selectedId_ = id; emit changed(); emit selectionChanged();
}
void MailAccountsController::connectGoogle() {
    if (!available() || submitting_ || oauthPending()) return;
    error_.clear(); message_.clear(); submitting_ = true; emit changed();
    const auto epoch = epoch_;
    api_.request("POST", "/api/mail/oauth/google/start", {}, core::Scope::workspace, &submitOwner_, [this, epoch](ApiResponse response) {
        if (epoch != epoch_ || contextGeneration_ != api_.context().generation) return;
        submitting_ = false;
        if (!response.ok()) { fail(response.error); return; }
        const auto data = response.json.value("data").toObject();
        const QUrl url(data.value("authorize_url").toString());
        const auto flow = data.value("flow_id").toString();
        if (!url.isValid() || url.scheme() != "https" || url.host() != "accounts.google.com" || !url.userInfo().isEmpty() ||
            url.port(443) != 443 || url.path() != "/o/oauth2/v2/auth" || url.hasFragment() ||
            !QRegularExpression("^[A-Za-z0-9_-]{1,256}$").match(flow).hasMatch()) {
            fail("The sign-in link was incomplete. Try connecting Gmail again."); return;
        }
        authorizeUrl_ = url; flowId_ = flow; oauthDeadline_ = QDateTime::currentMSecsSinceEpoch() + 10 * 60 * 1000;
        message_ = "Finish connecting Gmail in your browser. This window will update automatically.";
        poll_.start(); emit changed(); emit requestExternal(url);
    });
}
void MailAccountsController::checkOAuth() {
    syncContext();
    if (!oauthPending() || polling_ || submitting_ || !online()) return;
    if (QDateTime::currentMSecsSinceEpoch() >= oauthDeadline_) {
        clearOAuth(); fail("Google sign-in expired. Connect Gmail again to open a fresh sign-in window."); return;
    }
    polling_ = true;
    const auto epoch = epoch_; const auto flow = flowId_;
    api_.request("GET", "/api/mail/oauth/" + pathId(flow), {}, core::Scope::workspace, &oauthOwner_, [this, epoch, flow](ApiResponse response) {
        if (epoch != epoch_ || contextGeneration_ != api_.context().generation || flow != flowId_) return;
        polling_ = false;
        if (!response.ok()) {
            if (response.status == 404 || response.status == 410) { clearOAuth(); fail("This sign-in session expired. Connect Gmail again."); }
            else fail(response.networkError ? "Waiting for the connection to return. Gmail sign-in will be checked again automatically." : response.error);
            return;
        }
        const auto data = response.json.value("data").toObject();
        const auto status = data.value("status").toString();
        if (status == "connected") { clearOAuth(); connectionComplete(data.value("account_id").toString()); }
        else if (status == "failed") { clearOAuth(); fail(oauthError(data.value("error").toString())); }
        else { error_.clear(); emit changed(); }
    });
}
void MailAccountsController::reopenBrowser() { if (oauthPending() && !authorizeUrl_.isEmpty()) emit requestExternal(authorizeUrl_); }
void MailAccountsController::cancelOAuth() {
    syncContext();
    if (!oauthPending() || submitting_ || !available()) return;
    poll_.stop(); api_.cancelRequests(&oauthOwner_); polling_ = false; submitting_ = true; error_.clear(); emit changed();
    const auto epoch = epoch_; const auto flow = flowId_;
    api_.request("DELETE", "/api/mail/oauth/" + pathId(flow), {}, core::Scope::workspace, &oauthOwner_, [this, epoch, flow](ApiResponse response) {
        if (epoch != epoch_ || contextGeneration_ != api_.context().generation || flow != flowId_) return;
        submitting_ = false;
        if (!response.ok()) {
            poll_.start(); fail("Sign-in could not be cancelled yet. Keep this window open while we check the connection, or try Cancel again."); return;
        }
        const auto data = response.json.value("data").toObject();
        const auto status = data.value("status").toString();
        if (status == "connected") { clearOAuth(); connectionComplete(data.value("account_id").toString()); }
        else if (status == "failed") { clearOAuth(); error_.clear(); emit changed(); }
        else { poll_.start(); fail("Google sign-in is still pending. Try Cancel again."); }
    });
}
void MailAccountsController::clearOAuth() {
    poll_.stop(); api_.cancelRequests(&oauthOwner_); flowId_.clear(); authorizeUrl_.clear(); polling_ = false; message_.clear(); emit changed();
}
void MailAccountsController::connectImap(const QVariantMap& values, const QString& existingId) {
    if (!available() || submitting_ || oauthPending()) return;
    if (!existingId.isEmpty() && !knownAccount(existingId)) { fail("Refresh your mailboxes before reconnecting this account."); return; }
    const auto email = values.value("email_address").toString().trimmed();
    if (!QRegularExpression("^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$").match(email).hasMatch()) { fail("Enter your full email address."); return; }
    if (!existingId.isEmpty()) {
        for (const auto& value : accounts_) {
            const auto account = value.toMap();
            if (account.value("id").toString() == existingId && account.value("email_address").toString().compare(email, Qt::CaseInsensitive) != 0) {
                fail("To use a different email address, connect it as another mailbox."); return;
            }
        }
    }
    const auto password = values.value("password").toString();
    if (password.isEmpty()) { fail("Enter the mailbox password or an app password from your email provider."); return; }
    QJsonObject body{{"email_address", email}, {"password", password}, {"username", values.value("username").toString().trimmed().isEmpty() ? email : values.value("username").toString().trimmed()}};
    for (const auto* prefix : {"imap", "smtp"}) {
        const QString key(prefix);
        const auto host = values.value(key + "_host").toString().trimmed();
        if (key == "smtp" && host.isEmpty()) {
            if (values.value("smtp_enabled").toBool()) { fail("Enter the SMTP server or turn off outgoing mail."); return; }
            continue;
        }
        if (host.isEmpty() || host.contains(QRegularExpression("[\\s/@:]"))) { fail("Enter the " + key.toUpper() + " server name, such as mail.example.com."); return; }
        const auto security = values.value(key + "_security", "tls").toString();
        if (security != "tls" && security != "starttls") { fail("Choose TLS or STARTTLS for " + key.toUpper() + "."); return; }
        bool valid = false; const auto port = values.value(key + "_port").toInt(&valid);
        if (!valid || port < 1 || port > 65535) { fail("Enter a valid " + key.toUpper() + " port (1–65535)."); return; }
        body.insert(key + "_host", host); body.insert(key + "_port", port); body.insert(key + "_security", security);
    }
    if (body.contains("smtp_host") && values.value("different_smtp_login").toBool()) {
        const auto smtpUsername = values.value("smtp_username").toString().trimmed();
        const auto smtpPassword = values.value("smtp_password").toString();
        if (smtpUsername.isEmpty() || smtpPassword.isEmpty()) { fail("Enter both the SMTP username and password, or use the incoming mail sign-in."); return; }
        body.insert("smtp_username", smtpUsername); body.insert("smtp_password", smtpPassword);
    }
    submitting_ = true; error_.clear(); message_ = "Checking the mailbox connection…"; emit changed();
    const auto epoch = epoch_;
    api_.request(existingId.isEmpty() ? "POST" : "PUT", existingId.isEmpty() ? "/api/mail/accounts/imap" : "/api/mail/accounts/" + pathId(existingId) + "/imap", body,
        core::Scope::workspace, &submitOwner_, [this, epoch](ApiResponse response) {
            if (epoch != epoch_ || contextGeneration_ != api_.context().generation) return;
            submitting_ = false; message_.clear();
            if (!response.ok()) {
                if (response.networkError) { refresh(); fail("The connection was interrupted. Check your connected mailboxes before retrying; the account may already have been saved."); }
                else fail(response.error);
                return;
            }
            connectionComplete(response.json.value("data").toObject().value("id").toString());
        });
}
void MailAccountsController::connectionComplete(const QString& accountId) {
    awaitingSync_.clear(); if (!accountId.isEmpty()) awaitingSync_.insert(accountId);
    error_.clear(); message_ = "Mailbox connected. Your first synchronization is starting.";
    syncDeadline_ = QDateTime::currentMSecsSinceEpoch() + 2 * 60 * 1000; syncPoll_.start();
    refresh(); emit changed(); emit connected(); emit messagesChanged();
}
void MailAccountsController::synchronize(const QString& requestedId) {
    if (!available() || syncing_) return;
    const auto id = requestedId.isEmpty() ? selectedId_ : requestedId;
    QStringList ids;
    for (const auto& value : accounts_) { const auto candidate = value.toMap().value("id").toString(); if (id.isEmpty() || id == candidate) ids.append(candidate); }
    if (ids.isEmpty()) { fail("Connect a mailbox to start synchronizing your mail."); return; }
    awaitingSync_ = QSet<QString>(ids.begin(), ids.end());
    syncing_ = true; syncRequests_ = static_cast<int>(ids.size()); error_.clear(); message_ = "Requesting synchronization…"; emit changed();
    const auto epoch = epoch_;
    for (const auto& accountId : ids) api_.request("POST", "/api/mail/accounts/" + pathId(accountId) + "/sync", {}, core::Scope::workspace, &syncOwner_,
        [this, epoch](ApiResponse response) {
            if (epoch != epoch_ || contextGeneration_ != api_.context().generation) return;
            if (!response.ok()) error_ = response.error;
            if (--syncRequests_ == 0) {
                syncing_ = false; message_ = error_.isEmpty() ? "Synchronization queued. New messages will appear automatically." : QString{};
                syncDeadline_ = QDateTime::currentMSecsSinceEpoch() + 2 * 60 * 1000; syncPoll_.start(); refresh(); emit messagesChanged();
            }
            emit changed();
        });
}
void MailAccountsController::disconnectAccount(const QString& id) {
    if (!available() || submitting_ || !knownAccount(id)) return;
    submitting_ = true; error_.clear(); emit changed();
    const auto epoch = epoch_;
    api_.request("DELETE", "/api/mail/accounts/" + pathId(id), {}, core::Scope::workspace, &submitOwner_, [this, epoch](ApiResponse response) {
        if (epoch != epoch_ || contextGeneration_ != api_.context().generation) return;
        submitting_ = false;
        if (!response.ok()) { fail(response.error); return; }
        message_ = "Mailbox disconnected."; refresh(); emit changed(); emit messagesChanged();
    });
}
void MailAccountsController::openProviderHelp(const QString& imapHost) {
    if (imapHost == "imap.mail.me.com") emit requestExternal(QUrl("https://support.apple.com/en-ie/102525"));
    else if (imapHost == "imap.mail.yahoo.com") emit requestExternal(QUrl("https://help.yahoo.com/kb/SLN4075.html"));
    else if (imapHost == "imap.gmail.com") emit requestExternal(QUrl("https://support.google.com/accounts/answer/185833"));
}
void MailAccountsController::clearError() { error_.clear(); message_.clear(); emit changed(); }
}
