#pragma once
#include <QObject>
#include <QThread>
#include <functional>
namespace mokaid::desktop {
struct CacheBudget {
    qint64 maximumEntries{500};
    qint64 maximumBytes{256 * 1024 * 1024};
    qint64 maximumEntryBytes{8 * 1024 * 1024};
};
class CacheStore final : public QObject {
    Q_OBJECT
public:
    explicit CacheStore(const QString& directory, QObject* parent = nullptr, CacheBudget budget = {});
    ~CacheStore() override;
    void read(const QString& key, QObject* owner, std::function<void(QByteArray)> completion);
    void write(const QString& key, const QByteArray& bytes);
    void eraseAll();
private:
    QThread thread_;
    QObject worker_;
    QString connection_;
    const CacheBudget budget_;
};
}
