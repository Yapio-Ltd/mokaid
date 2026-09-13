#include <mokaid/storage/cache_store.hpp>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QPointer>
#include <QSqlDatabase>
#include <QSqlQuery>
#include <QVariant>
#include <QUuid>
namespace mokaid::desktop {
CacheStore::CacheStore(const QString& directory, QObject* parent, CacheBudget budget) : QObject(parent), connection_(QUuid::createUuid().toString()), budget_(budget) {
    if (budget.maximumEntries <= 0 || budget.maximumBytes <= 0 || budget.maximumEntryBytes <= 0
        || budget.maximumEntryBytes > budget.maximumBytes) qFatal("Invalid cache resource budget");
    QDir().mkpath(directory);
    QFile::setPermissions(directory, QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner);
    worker_.moveToThread(&thread_); thread_.start();
    QMetaObject::invokeMethod(&worker_, [connection = connection_, directory] {
        auto db = QSqlDatabase::addDatabase("QSQLITE", connection);
        db.setDatabaseName(directory + "/recent.sqlite");
        if (!db.open()) return;
        QSqlQuery q(db);
        q.exec("PRAGMA journal_mode=WAL");
        q.exec("PRAGMA busy_timeout=5000");
        q.exec("CREATE TABLE IF NOT EXISTS cache (key TEXT PRIMARY KEY, payload BLOB NOT NULL, updated INTEGER NOT NULL)");
    }, Qt::QueuedConnection);
}
CacheStore::~CacheStore() {
    QMetaObject::invokeMethod(&worker_, [connection = connection_, target = QThread::currentThread(), this] {
        { auto db = QSqlDatabase::database(connection, false); db.close(); }
        QSqlDatabase::removeDatabase(connection);
        worker_.moveToThread(target);
    }, Qt::BlockingQueuedConnection);
    thread_.quit(); thread_.wait();
}
void CacheStore::read(const QString& key, QObject* owner, std::function<void(QByteArray)> done) {
    QPointer<QObject> guard(owner);
    QMetaObject::invokeMethod(&worker_, [this, connection = connection_, key, guard, done = std::move(done)]() mutable {
        QByteArray bytes;
        auto db = QSqlDatabase::database(connection, false);
        if (db.isOpen()) {
            QSqlQuery q(db); q.prepare("SELECT payload FROM cache WHERE key=?"); q.addBindValue(key);
            if (q.exec() && q.next()) bytes = q.value(0).toByteArray();
        }
        // Return to this object's GUI thread before inspecting the owner's lifetime.
        // The destructor drains this worker; QObject removes queued callbacks on destruction.
        QMetaObject::invokeMethod(this, [guard, done = std::move(done), bytes]() mutable { if (guard) done(bytes); }, Qt::QueuedConnection);
    }, Qt::QueuedConnection);
}
void CacheStore::write(const QString& key, const QByteArray& bytes) {
    if (bytes.size() > budget_.maximumEntryBytes) return;
    QMetaObject::invokeMethod(&worker_, [connection = connection_, key, bytes, budget = budget_] {
        auto db = QSqlDatabase::database(connection, false); if (!db.isOpen()) return;
        QSqlQuery q(db); q.prepare("INSERT OR REPLACE INTO cache(key,payload,updated) VALUES(?,?,?)");
        q.addBindValue(key); q.addBindValue(bytes); q.addBindValue(QDateTime::currentMSecsSinceEpoch()); q.exec();
        // Bound both count and payload bytes; 500 maximum-size artifacts must not grow to 4 GiB.
        q.prepare("DELETE FROM cache WHERE key IN (SELECT key FROM (SELECT key, "
                  "ROW_NUMBER() OVER (ORDER BY updated DESC,rowid DESC) AS position, "
                  "SUM(LENGTH(payload)) OVER (ORDER BY updated DESC,rowid DESC) AS total_bytes "
                  "FROM cache) WHERE position>? OR total_bytes>?)");
        q.addBindValue(budget.maximumEntries); q.addBindValue(budget.maximumBytes); q.exec();
    }, Qt::QueuedConnection);
}
void CacheStore::eraseAll() {
    QMetaObject::invokeMethod(&worker_, [connection = connection_] {
        auto db = QSqlDatabase::database(connection, false);
        if (db.isOpen()) { QSqlQuery q(db); q.exec("DELETE FROM cache"); }
    }, Qt::QueuedConnection);
}
}
