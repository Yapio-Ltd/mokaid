#include <mokaid/storage/cache_store.hpp>
#include <QTemporaryDir>
#include <QtTest>
#include <memory>
using namespace mokaid::desktop;
class CacheTests final : public QObject {
    Q_OBJECT
private slots:
    void byteAndEntryBudgetsEvictOldestWrites() {
        QTemporaryDir folder; QVERIFY(folder.isValid());
        CacheStore cache(folder.path(), nullptr, {2, 8, 6}); QObject owner;
        cache.write("a", "aaa"); cache.write("b", "bbb"); cache.write("c", "ccc");
        QByteArray a, b, c; int returned = 0;
        cache.read("a", &owner, [&](QByteArray bytes) { a = bytes; ++returned; });
        cache.read("b", &owner, [&](QByteArray bytes) { b = bytes; ++returned; });
        cache.read("c", &owner, [&](QByteArray bytes) { c = bytes; ++returned; });
        QTRY_COMPARE(returned, 3); QVERIFY(a.isEmpty()); QCOMPARE(b, QByteArray("bbb")); QCOMPARE(c, QByteArray("ccc"));
        cache.write("too-large", "1234567"); cache.write("d", "dddddd");
        returned = 0; QByteArray d, tooLarge;
        cache.read("d", &owner, [&](QByteArray bytes) { d = bytes; ++returned; });
        cache.read("c", &owner, [&](QByteArray bytes) { c = bytes; ++returned; });
        cache.read("too-large", &owner, [&](QByteArray bytes) { tooLarge = bytes; ++returned; });
        QTRY_COMPARE(returned, 3); QCOMPARE(d, QByteArray("dddddd")); QVERIFY(c.isEmpty()); QVERIFY(tooLarge.isEmpty());
        cache.eraseAll(); returned = 0;
        cache.read("d", &owner, [&](QByteArray bytes) { d = bytes; ++returned; });
        QTRY_COMPARE(returned, 1); QVERIFY(d.isEmpty());
    }
    void callbackReturnsOnOwnerThreadAndSurvivesOwnerDeletion() {
        QTemporaryDir folder; QVERIFY(folder.isValid()); CacheStore cache(folder.path());
        cache.write("saved", "content"); auto owner = std::make_unique<QObject>(); bool unwanted = false, returned = false;
        cache.read("saved", owner.get(), [&](QByteArray) { unwanted = true; }); owner.reset();
        cache.read("saved", this, [&](QByteArray bytes) { QCOMPARE(QThread::currentThread(), thread()); QCOMPARE(bytes, QByteArray("content")); returned = true; });
        QTRY_VERIFY(returned); QVERIFY(!unwanted);
    }
};
QTEST_GUILESS_MAIN(CacheTests)
#include "cache_tests.moc"
