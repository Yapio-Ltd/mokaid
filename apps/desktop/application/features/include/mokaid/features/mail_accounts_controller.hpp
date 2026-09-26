#pragma once
#include <mokaid/application/session_controller.hpp>
#include <QTimer>
#include <QSet>
#include <QVariantList>

namespace mokaid::desktop {
// Only the authenticated API handles OAuth tokens and persisted mailbox secrets.
// The native client holds the IMAP password only for the submitted request.
class MailAccountsController final : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList accounts READ accounts NOTIFY changed)
    Q_PROPERTY(QString selectedId READ selectedId NOTIFY changed)
    Q_PROPERTY(QVariantMap selectedAccount READ selectedAccount NOTIFY changed)
    Q_PROPERTY(QString error READ error NOTIFY changed)
    Q_PROPERTY(QString message READ message NOTIFY changed)
    Q_PROPERTY(bool online READ online NOTIFY changed)
    Q_PROPERTY(bool refreshing READ refreshing NOTIFY changed)
    Q_PROPERTY(bool submitting READ submitting NOTIFY changed)
    Q_PROPERTY(bool syncing READ syncing NOTIFY changed)
    Q_PROPERTY(bool oauthPending READ oauthPending NOTIFY changed)
public:
    MailAccountsController(ApiClient&, SessionController&, QObject* parent = nullptr);
    ~MailAccountsController() override;
    QVariantList accounts() const { return accounts_; }
    QString selectedId() const { return selectedId_; }
    QVariantMap selectedAccount() const;
    QString error() const { return error_; }
    QString message() const { return message_; }
    bool online() const { return api_.context().online && api_.context().authenticated; }
    bool refreshing() const { return refreshing_; }
    bool submitting() const { return submitting_; }
    bool syncing() const { return syncing_; }
    bool oauthPending() const { return !flowId_.isEmpty(); }
    Q_INVOKABLE void setActive(bool active);
    Q_INVOKABLE void refresh();
    Q_INVOKABLE void select(const QString& id);
    Q_INVOKABLE void connectGoogle();
    Q_INVOKABLE void checkOAuth();
    Q_INVOKABLE void reopenBrowser();
    Q_INVOKABLE void cancelOAuth();
    Q_INVOKABLE void connectImap(const QVariantMap& values, const QString& existingId = {});
    Q_INVOKABLE void synchronize(const QString& id = {});
    Q_INVOKABLE void disconnectAccount(const QString& id);
    Q_INVOKABLE void clearError();
    Q_INVOKABLE void openProviderHelp(const QString& imapHost);
signals:
    void changed();
    void contextReset();
    void connected();
    void selectionChanged();
    void messagesChanged();
    void requestExternal(QUrl url);
private:
    void syncContext();
    bool available();
    bool knownAccount(const QString&) const;
    void connectionComplete(const QString& accountId);
    void clearOAuth();
    void fail(const QString&);
    ApiClient& api_;
    QVariantList accounts_;
    QString selectedId_, error_, message_, flowId_;
    QUrl authorizeUrl_;
    QSet<QString> awaitingSync_;
    QTimer poll_, syncPoll_;
    QObject listOwner_, submitOwner_, oauthOwner_, syncOwner_;
    quint64 contextGeneration_{}, epoch_{};
    qint64 oauthDeadline_{}, syncDeadline_{};
    int syncRequests_{};
    bool active_{}, refreshing_{}, submitting_{}, syncing_{}, polling_{};
};
}
