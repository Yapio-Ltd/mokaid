#pragma once
#include <mokaid/core/policy.hpp>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QPointer>
#include <QSet>
#include <QHash>
#include <QThreadPool>
#include <QUrl>
#include <functional>
#include <memory>

namespace mokaid::desktop {
struct ApiResponse {
    int status{};
    QJsonObject json;
    QByteArray bytes;
    QString error;
    bool networkError{};
    [[nodiscard]] bool ok() const { return status >= 200 && status < 300 && error.isEmpty(); }
};
class ApiClient final : public QObject {
    Q_OBJECT
public:
    using Completion = std::function<void(ApiResponse)>;
    explicit ApiClient(QUrl origin, QObject* parent = nullptr);
    ~ApiClient() override;
    [[nodiscard]] QUrl origin() const { return origin_; }
    [[nodiscard]] const core::SessionContext& context() const { return context_; }
    [[nodiscard]] QByteArray accessToken() const { return token_; }
    void setSession(const QByteArray& token, const QString& user, bool admin);
    void setWorkspace(const QString& workspace);
    void setOnline(bool online);
    void reset();
    void cancelAll();
    void cancelRequests(QObject* owner);
    void request(const QByteArray& method, const QString& path, const QJsonObject& body,
                 core::Scope scope, QObject* owner, Completion completion);
    void upload(const QString& path, const QList<QUrl>& files, const QJsonObject& fields,
                core::Scope scope, QObject* owner, Completion completion);
signals:
    void sessionExpired();
    void administratorDenied();
    void onlineChanged(bool online);
private:
    struct Cancellation { bool cancelled{}; };
    QNetworkRequest makeRequest(const QString& path, core::Scope scope) const;
    void track(QNetworkReply* reply, core::Scope scope, QObject* owner, Completion completion);
    QUrl origin_;
    QNetworkAccessManager manager_;
    QByteArray token_;
    core::SessionContext context_;
    QSet<QNetworkReply*> replies_;
    QHash<QNetworkReply*, QPointer<QObject>> owners_;
    QMultiHash<QObject*, std::shared_ptr<Cancellation>> operations_;
    QThreadPool decodePool_;
};
}
