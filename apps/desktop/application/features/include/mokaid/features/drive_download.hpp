#pragma once
#include <mokaid/network/api_client.hpp>
#include <QThreadPool>
#include <QVariantMap>
#include <atomic>
#include <memory>

namespace mokaid::desktop {
// A file export is a one-use, account-bound transaction, not a navigation URL.
class DriveDownload final : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool busy READ busy NOTIFY changed)
    Q_PROPERTY(QString error READ error NOTIFY changed)
    Q_PROPERTY(QString status READ status NOTIFY changed)
    Q_PROPERTY(QString pendingTransaction READ pendingTransaction NOTIFY changed)
public:
    explicit DriveDownload(ApiClient& api, QObject* parent = nullptr);
    ~DriveDownload() override;
    static QString safeFileName(QString name);
    void request(const QVariantMap& record);
    void reset();
    void cancelForConnectionLoss();
    bool busy() const { return busy_; }
    QString error() const { return error_; }
    QString status() const { return status_; }
    QString pendingTransaction() const { return transaction_; }
    Q_INVOKABLE void save(const QString& transaction, const QUrl& destination);
    Q_INVOKABLE void cancel(const QString& transaction = {});
signals:
    void changed();
    void saveRequested(QString transaction, QUrl suggestedFile);
private:
    bool current(const QString& transaction) const;
    void fail(QString message);
    ApiClient& api_;
    QThreadPool writer_;
    std::shared_ptr<std::atomic_bool> cancelled_;
    QString transaction_, path_, user_, workspace_, error_, status_;
    quint64 generation_{};
    bool busy_{};
};
}
