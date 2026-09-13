#pragma once
#include <mokaid/application/session_controller.hpp>
#include <mokaid/storage/cache_store.hpp>
#include <QHash>
#include <QSet>
#include <QTimer>

namespace mokaid::desktop {
// Customer-workspace activity only: this controller never requests admin data.
class ActivityController final : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList searchResults READ searchResults NOTIFY changed)
    Q_PROPERTY(QVariantList notifications READ notifications NOTIFY changed)
    Q_PROPERTY(int unreadCount READ unreadCount NOTIFY changed)
    Q_PROPERTY(QString query READ query WRITE setQuery NOTIFY changed)
    Q_PROPERTY(bool busy READ busy NOTIFY changed)
    Q_PROPERTY(QString error READ error NOTIFY changed)
public:
    ActivityController(ApiClient& api, SessionController& session, PhoenixClient& realtime,
                       CacheStore& cache, QObject* parent = nullptr);
    QVariantList searchResults() const { return searchResults_; }
    QVariantList notifications() const { return notifications_; }
    int unreadCount() const;
    QString query() const { return query_; }
    bool busy() const { return searchBusy_ || notificationsBusy_ || creating_ || !marking_.isEmpty(); }
    QString error() const { return error_; }
    Q_INVOKABLE void refreshNotifications();
    Q_INVOKABLE void markRead(const QString& id);
    Q_INVOKABLE void setQuery(const QString& text);
    Q_INVOKABLE void createWorkspace(const QString& name, const QString& industry);
    Q_INVOKABLE void openSearchResult(const QString& page, const QString& id);
    Q_INVOKABLE void openNotification(const QString& id);
signals:
    void changed();
    void navigateRequested(QString page, QString id);
    void workspaceCreated(QString id);
private:
    void contextChanged();
    void clear();
    void runSearch();
    void acceptSearch(const QJsonObject& response);
    void acceptNotifications(const QJsonObject& response);
    void readSearchCache(const QString& path, quint64 epoch, quint64 generation, const QString& context);
    void readNotificationsCache(quint64 epoch, quint64 generation, const QString& context);
    QString userId() const;
    QString workspaceId() const;
    QString contextKey() const;
    QString cacheKey(const QString& path) const;
    bool canReadCache() const;
    bool current(quint64 generation, const QString& context) const;
    void fail(QString error);
    ApiClient& api_;
    SessionController& session_;
    PhoenixClient& realtime_;
    CacheStore& cache_;
    QObject searchOwner_, notificationOwner_, mutationOwner_;
    QTimer searchTimer_, notificationTimer_;
    QVariantList searchResults_, notifications_;
    QString query_, error_, context_, pendingWorkspace_, pendingUser_;
    QSet<QString> marking_;
    QHash<QString,QString> readAt_;
    quint64 searchEpoch_{}, notificationEpoch_{}, generation_{};
    bool searchBusy_{}, notificationsBusy_{}, creating_{}, refreshPending_{};
};
}
