#pragma once
#include <mokaid/network/api_client.hpp>
#include <mokaid/network/phoenix_client.hpp>
#include <mokaid/platform/credential_store.hpp>
#include <QJsonArray>
#include <QSettings>
#include <QTcpServer>
#include <QTimer>

namespace mokaid::desktop {
class SessionController final : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool authenticated READ authenticated NOTIFY changed)
    Q_PROPERTY(bool busy READ busy NOTIFY changed)
    Q_PROPERTY(bool online READ online NOTIFY changed)
    Q_PROPERTY(bool administrator READ administrator NOTIFY changed)
    Q_PROPERTY(QString error READ error NOTIFY changed)
    Q_PROPERTY(QVariantMap user READ user NOTIFY changed)
    Q_PROPERTY(QVariantList workspaces READ workspaces NOTIFY changed)
    Q_PROPERTY(QString workspaceId READ workspaceId WRITE selectWorkspace NOTIFY changed)
public:
    SessionController(ApiClient& api, PhoenixClient& realtime, QObject* parent = nullptr, QUrl trustedWebOrigin = {});
    void restore();
    bool authenticated() const { return authenticated_; }
    bool busy() const { return busy_ || refreshing_ || identityLoading_; }
    bool online() const { return api_.context().online; }
    bool administrator() const { return online() && api_.context().platform_admin; }
    QString error() const { return error_; }
    QVariantMap user() const { return user_.toVariantMap(); }
    QVariantList workspaces() const { return workspaces_.toVariantList(); }
    QString workspaceId() const { return workspace_; }
    Q_INVOKABLE void signIn();
    Q_INVOKABLE void cancelSignIn();
    Q_INVOKABLE void signOut();
    Q_INVOKABLE void retry();
    Q_INVOKABLE void selectWorkspace(const QString& id);
    void reloadIdentity();
signals:
    void changed();
    void established();
    void cleared();
    void workspaceChanged();
private:
    void renew();
    void acceptTokens(const ApiResponse& response);
    void receiveCallback();
    void fail(const QString& message);
    void persistIdentity();
    QString identityKey() const;
    ApiClient& api_;
    PhoenixClient& realtime_;
    const QUrl browserOrigin_;
    CredentialStore vault_;
    QSettings settings_;
    QTcpServer callback_;
    QTimer expiration_, loginTimeout_, connectivity_;
    QByteArray refreshToken_, verifier_;
    QString state_, redirect_, workspace_, error_;
    QJsonObject user_;
    QJsonArray workspaces_;
    quint64 loginGeneration_{};
    bool authenticated_{}, busy_{}, refreshing_{}, identityLoading_{};
};
}
