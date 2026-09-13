#pragma once
#include <QJsonObject>
#include <QObject>
#include <QTimer>
#include <QWebSocket>
#include <QHash>
#include <QSet>
namespace mokaid::desktop {
class PhoenixClient final : public QObject {
    Q_OBJECT
public:
    explicit PhoenixClient(QObject* parent = nullptr);
    void start(const QUrl& origin, const QByteArray& token, const QString& workspace, const QString& user);
    void stop();
signals:
    void eventReceived(const QString& topic, const QString& event, const QJsonObject& payload);
    void connectionChanged(bool online);
    void rejoined();
    void authenticationExpired();
private:
    void open();
    QString send(const QString& topic, const QString& event, const QJsonObject& payload, const QString& join = {});
    void receive(const QString& message);
    QWebSocket socket_;
    QTimer heartbeat_, reconnect_, joinTimeout_;
    QUrl url_;
    QByteArray token_;
    QStringList topics_;
    QHash<QString, QString> joins_;
    QSet<QString> joined_;
    QString pendingHeartbeat_;
    quint64 ref_{};
    int attempts_{};
    bool running_{};
};
}
