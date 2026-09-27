#pragma once
#include <mokaid/application/session_controller.hpp>
#include <QTimer>
#include <QVariantList>

namespace mokaid::desktop {
// Google tokens and PKCE exchanges stay on the server. The desktop sees only
// short-lived flow identifiers and allowlisted connection display metadata.
class GoogleConnectionsController final : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList services READ services CONSTANT)
    Q_PROPERTY(QVariantList connections READ connections NOTIFY changed)
    Q_PROPERTY(QString providerKey READ providerKey NOTIFY changed)
    Q_PROPERTY(QString providerName READ providerName NOTIFY changed)
    Q_PROPERTY(QString error READ error NOTIFY changed)
    Q_PROPERTY(QString message READ message NOTIFY changed)
    Q_PROPERTY(bool needsAttention READ needsAttention NOTIFY changed)
    Q_PROPERTY(bool online READ online NOTIFY changed)
    Q_PROPERTY(bool refreshing READ refreshing NOTIFY changed)
    Q_PROPERTY(bool submitting READ submitting NOTIFY changed)
    Q_PROPERTY(bool pending READ pending NOTIFY changed)
public:
    GoogleConnectionsController(ApiClient&, SessionController&, QObject* parent = nullptr);
    ~GoogleConnectionsController() override;
    QVariantList services() const;
    QVariantList connections() const { return connections_; }
    QString providerKey() const { return providerKey_; }
    QString providerName() const;
    QString error() const { return error_; }
    QString message() const { return message_; }
    bool needsAttention() const { return needsAttention_; }
    bool online() const { return core::mayRequest(api_.context(), core::Scope::workspace, true); }
    bool refreshing() const { return refreshing_; }
    bool submitting() const { return submitting_; }
    bool pending() const { return !flowId_.isEmpty(); }
    Q_INVOKABLE void setActive(bool active);
    Q_INVOKABLE void refresh();
    Q_INVOKABLE void start(const QString& providerKey);
    Q_INVOKABLE void check();
    Q_INVOKABLE void cancel();
    Q_INVOKABLE void reopenBrowser();
    Q_INVOKABLE void clearFeedback();
signals:
    void changed();
    void contextReset();
    void connected(QString providerKey);
    void cancelled();
    void requestExternal(QUrl url);
private:
    void syncContext();
    bool available();
    bool supported(const QString&) const;
    void acceptCompletion(const QJsonObject& data);
    void clearFlow();
    void fail(const QString& message);
    ApiClient& api_;
    QVariantList connections_;
    QString providerKey_, flowId_, error_, message_;
    QUrl authorizeUrl_;
    QTimer poll_;
    QObject listOwner_, submitOwner_, pollOwner_;
    quint64 contextGeneration_{}, epoch_{};
    qint64 deadline_{};
    bool needsAttention_{}, active_{}, refreshing_{}, submitting_{}, polling_{};
};
}
