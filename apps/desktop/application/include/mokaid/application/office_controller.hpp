#pragma once
#include <mokaid/application/session_controller.hpp>
#include <mokaid/storage/cache_store.hpp>
#include <QVariantList>

namespace mokaid::desktop {
class OfficeController final : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList agents READ agents NOTIFY agentsChanged)
    Q_PROPERTY(QVariantMap selectedAgent READ selectedAgent NOTIFY changed)
    Q_PROPERTY(QVariantList messages READ messages NOTIFY messagesChanged)
    Q_PROPERTY(QVariantList conversations READ conversations NOTIFY changed)
    Q_PROPERTY(QString conversationId READ conversationId NOTIFY changed)
    Q_PROPERTY(QString draft READ draft WRITE setDraft NOTIFY changed)
    Q_PROPERTY(QString stream READ stream NOTIFY streamChanged)
    Q_PROPERTY(QString error READ error NOTIFY changed)
    Q_PROPERTY(bool loading READ loading NOTIFY changed)
    Q_PROPERTY(bool sending READ sending NOTIFY changed)
    Q_PROPERTY(bool hasDrafts READ hasDrafts NOTIFY changed)
public:
    OfficeController(ApiClient&, SessionController&, PhoenixClient&, CacheStore&, QObject* parent = nullptr);
    QVariantList agents() const { return agents_; }
    QVariantMap selectedAgent() const { return selected_; }
    QVariantList messages() const { return messages_; }
    QVariantList conversations() const { return conversations_; }
    QString conversationId() const { return conversation_; }
    QString draft() const { return draft_; }
    QString stream() const { return stream_; }
    QString error() const { return error_; }
    bool loading() const { return loading_; }
    bool sending() const { return sending_; }
    bool hasDrafts() const;
    Q_INVOKABLE void refresh();
    Q_INVOKABLE void selectAgent(const QString& id);
    Q_INVOKABLE void closeChat();
    Q_INVOKABLE void setDraft(const QString& text);
    Q_INVOKABLE void send(const QVariantList& driveItemIds = {});
    Q_INVOKABLE void selectConversation(const QString& id);
    Q_INVOKABLE void newConversation();
    Q_INVOKABLE void refreshMessages();
signals:
    void changed();
    void agentsChanged();
    void messagesChanged();
    void streamChanged();
private:
    QString cacheKey(const QString& path) const;
    void get(const QString& path, std::function<void(QJsonObject)> done);
    void reset();
    void receive(const QString& topic, const QString& event, const QJsonObject& payload);
    ApiClient& api_;
    SessionController& session_;
    PhoenixClient& realtime_;
    CacheStore& cache_;
    QVariantList agents_, messages_, conversations_;
    QVariantMap selected_;
    QHash<QString, QString> drafts_;
    QString conversation_, draft_, stream_, streamId_, error_;
    QTimer publishStream_, debounceRefresh_;
    quint64 generation_{}, chatGeneration_{};
    bool loading_{}, sending_{};
};
}
