#pragma once
#include <mokaid/features/mail_accounts_controller.hpp>
#include <mokaid/features/drive_download.hpp>
#include <QJsonArray>

namespace mokaid::desktop {
class MailCenterController final : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList messages READ messages NOTIFY changed)
    Q_PROPERTY(QVariantList folders READ folders NOTIFY changed)
    Q_PROPERTY(QVariantList labels READ labels NOTIFY changed)
    Q_PROPERTY(QVariantMap selected READ selected NOTIFY changed)
    Q_PROPERTY(QString selectedId READ selectedId NOTIFY changed)
    Q_PROPERTY(QString folder READ folder NOTIFY changed)
    Q_PROPERTY(QString filter READ filter NOTIFY changed)
    Q_PROPERTY(QString sort READ sort NOTIFY changed)
    Q_PROPERTY(QString query READ query NOTIFY changed)
    Q_PROPERTY(QString label READ label NOTIFY changed)
    Q_PROPERTY(QString error READ error NOTIFY changed)
    Q_PROPERTY(QString notice READ notice NOTIFY changed)
    Q_PROPERTY(bool online READ online NOTIFY changed)
    Q_PROPERTY(bool busy READ busy NOTIFY changed)
    Q_PROPERTY(bool detailLoading READ detailLoading NOTIFY changed)
    Q_PROPERTY(bool mutating READ mutating NOTIFY changed)
    Q_PROPERTY(bool hasMore READ hasMore NOTIFY changed)
    Q_PROPERTY(bool canSend READ canSend NOTIFY changed)
    Q_PROPERTY(bool canManage READ canManage NOTIFY changed)
    Q_PROPERTY(QVariantMap draft READ draft NOTIFY changed)
    Q_PROPERTY(QVariantList draftAttachments READ draftAttachments NOTIFY changed)
    Q_PROPERTY(bool composing READ composing NOTIFY changed)
    Q_PROPERTY(bool hasDraft READ hasDraft NOTIFY changed)
    Q_PROPERTY(bool sending READ sending NOTIFY changed)
    Q_PROPERTY(bool deliveryUncertain READ deliveryUncertain NOTIFY changed)
public:
    MailCenterController(ApiClient&, SessionController&, MailAccountsController&, DriveDownload&, QObject* parent = nullptr);
    ~MailCenterController() override;
    QVariantList messages() const { return messages_; }
    QVariantList folders() const { return folders_; }
    QVariantList labels() const { return labels_; }
    QVariantMap selected() const { return selected_; }
    QString selectedId() const { return selectedId_; }
    QString folder() const { return folder_; }
    QString filter() const { return filter_; }
    QString sort() const { return sort_; }
    QString query() const { return query_; }
    QString label() const { return label_; }
    QString error() const { return error_; }
    QString notice() const { return notice_; }
    bool online() const { return api_.context().online && core::mayRequest(api_.context(), core::Scope::workspace, false); }
    bool busy() const { return busy_; }
    bool detailLoading() const { return detailLoading_; }
    bool mutating() const { return mutating_; }
    bool hasMore() const { return hasMore_; }
    bool canSend() const { return online() && accounts_.canSend(); }
    bool canManage() const { return online() && accounts_.canManage(); }
    QVariantMap draft() const { return draft_; }
    QVariantList draftAttachments() const;
    bool composing() const { return composing_; }
    bool hasDraft() const;
    bool sending() const { return sending_; }
    bool deliveryUncertain() const { return uncertain_; }
    static QString safeBody(const QString& html, const QString& plain);
    static bool safeLink(const QUrl&);
    Q_INVOKABLE void setActive(bool);
    Q_INVOKABLE void refresh();
    Q_INVOKABLE void loadMore();
    Q_INVOKABLE void setFolder(const QString&);
    Q_INVOKABLE void setFilter(const QString&);
    Q_INVOKABLE void setSort(const QString&);
    Q_INVOKABLE void search(const QString&);
    Q_INVOKABLE void setLabel(const QString&);
    Q_INVOKABLE void select(const QString&);
    Q_INVOKABLE void closeMessage();
    Q_INVOKABLE void act(const QString& action, bool value = true, const QString& id = {});
    Q_INVOKABLE void attachment(const QString& id, bool preview);
    Q_INVOKABLE void openLink(const QUrl&);
    Q_INVOKABLE void compose(bool reply = false);
    Q_INVOKABLE void closeComposer();
    Q_INVOKABLE void discardDraft();
    Q_INVOKABLE void setDraft(const QString& key, const QString& value);
    Q_INVOKABLE void addAttachments(const QList<QUrl>&);
    Q_INVOKABLE void removeAttachment(int);
    Q_INVOKABLE void send();
    Q_INVOKABLE void checkDelivery();
signals:
    void changed();
    void contextReset();
    void openAttachment(QVariantMap file);
    void requestExternal(QUrl url);
private:
    void syncContext();
    void fetchMessages(bool more);
    void fetchFolders();
    void finishSend(const QJsonObject&);
    void fail(const QString&);
    void replaceMessage(const QVariantMap&);
    ApiClient& api_;
    MailAccountsController& accounts_;
    DriveDownload& download_;
    QVariantList messages_, folders_, labels_;
    QVariantMap selected_, draft_;
    QJsonArray outgoingAttachments_;
    QJsonObject submitted_;
    QString selectedId_, folder_{"inbox"}, filter_{"all"}, sort_{"newest"}, query_, label_, error_, notice_, requestId_, outboxId_;
    QObject listOwner_, folderOwner_, detailOwner_, actionOwner_, sendOwner_;
    QTimer searchTimer_;
    quint64 generation_{}, listRevision_{}, detailRevision_{};
    int submissionAttempts_{};
    bool active_{}, busy_{}, detailLoading_{}, mutating_{}, hasMore_{}, composing_{}, sending_{}, uncertain_{}, sendFailed_{};
};
}
