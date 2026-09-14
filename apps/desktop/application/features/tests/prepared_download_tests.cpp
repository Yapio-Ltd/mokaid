#include "../prepared_download.hpp"
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QSemaphore>
#include <QScopeGuard>
#include <QTemporaryDir>
#include <QThread>
#include <QThreadPool>
#include <QTimer>
#include <QtTest>

using mokaid::desktop::detail::PreparedDownload;

namespace {
QByteArray contents(const QString& path) {
    QFile file(path);
    return file.open(QIODevice::ReadOnly) ? file.readAll() : QByteArray{};
}
bool writeFile(const QString& path, const QByteArray& bytes) {
    QFile file(path);
    return file.open(QIODevice::WriteOnly) && file.write(bytes)==bytes.size() && file.flush();
}
QStringList temporaries(const QTemporaryDir& directory) {
    return QDir(directory.path()).entryList({".mokaid-download-*"},QDir::Files|QDir::Hidden);
}
// The same preparation API used by DriveDownload, always on a bounded worker.
std::shared_ptr<PreparedDownload> prepare(const QString& path, const QByteArray& bytes,
    const std::atomic_bool& cancelled, const PreparedDownload::Synchronize& sync=PreparedDownload::synchronizeFile) {
    QThreadPool writer; writer.setMaxThreadCount(1);
    std::shared_ptr<PreparedDownload> result;
    writer.start([&] { result=PreparedDownload::prepare(path,bytes,cancelled,sync); });
    writer.waitForDone();
    return result;
}
}

class PreparedDownloadTests final : public QObject {
    Q_OBJECT
private slots:
    void preparationRefusesMainThread() {
        QTemporaryDir directory; std::atomic_bool cancelled{false}; bool synchronized=false;
        const auto result=PreparedDownload::prepare(directory.filePath("never-written"),"bytes",cancelled,
            [&](QFileDevice&) { synchronized=true; return true; });
        QVERIFY(!result); QVERIFY(!synchronized); QVERIFY(temporaries(directory).isEmpty());
    }
    void diskSynchronizationDoesNotBlockTheOwnerEventLoop() {
        QTemporaryDir directory; QVERIFY(directory.isValid()); const auto path=directory.filePath("download.txt");
        QThreadPool writer; writer.setMaxThreadCount(1);
        std::atomic_bool cancelled{false}, entered{false}, finished{false}, workerThread{false};
        QSemaphore release;
        std::shared_ptr<PreparedDownload> prepared;
        auto* ownerThread=QThread::currentThread();
        // Always release the worker even if a QTRY assertion returns early.
        const auto unblock=qScopeGuard([&] { release.release(); writer.waitForDone(); });
        writer.start([&] {
            prepared=PreparedDownload::prepare(path,QByteArray(1024*1024,'x'),cancelled,[&](QFileDevice& file) {
                workerThread.store(QThread::currentThread()!=ownerThread); entered.store(true);
                release.acquire();
                return PreparedDownload::synchronizeFile(file); // real native fsync/FlushFileBuffers
            });
            finished.store(true);
        });
        QTRY_VERIFY(entered.load()); QVERIFY(workerThread.load());
        bool eventProcessed=false;
        QTimer::singleShot(0,this,[&] { eventProcessed=true; });
        QTRY_VERIFY(eventProcessed); QVERIFY(!finished.load()); QVERIFY(!QFileInfo::exists(path));
        release.release(); QTRY_VERIFY(finished.load()); writer.waitForDone(); QVERIFY(prepared);
        QVERIFY(prepared->publish(false)); QCOMPARE(contents(path),QByteArray(1024*1024,'x'));
        QVERIFY(temporaries(directory).isEmpty());
    }
    void synchronizationFailurePreservesDestinationAndRemovesTemporary() {
        QTemporaryDir directory; const auto path=directory.filePath("existing.txt");
        QVERIFY(writeFile(path,"previous bytes")); std::atomic_bool cancelled{false}; bool synchronized=false;
        const auto result=prepare(path,QByteArray(1024*1024,'x'),cancelled,[&](QFileDevice& file) {
            synchronized=true;
            // Inject the OS sync failure boundary (e.g. ENOSPC/EIO), not success.
            file.flush(); return false;
        });
        QVERIFY(synchronized); QVERIFY(!result); QCOMPARE(contents(path),QByteArray("previous bytes"));
        QVERIFY(temporaries(directory).isEmpty());
    }
    void cancellationAfterNativeSyncCannotPublish() {
        QTemporaryDir directory; const auto path=directory.filePath("existing.txt");
        QVERIFY(writeFile(path,"original")); std::atomic_bool cancelled{false}; bool synchronized=false;
        auto result=prepare(path,"replacement",cancelled,[&](QFileDevice& file) {
            synchronized=PreparedDownload::synchronizeFile(file); cancelled.store(true); return synchronized;
        });
        QVERIFY(synchronized); QVERIFY(!result); QCOMPARE(contents(path),QByteArray("original")); QVERIFY(temporaries(directory).isEmpty());
    }
    void preparationAndPublicationAreSeparateAndSingleUse() {
        QTemporaryDir directory; const auto path=directory.filePath(QString::fromUtf8("récap-🙂.json"));
        QVERIFY(writeFile(path,"original")); std::atomic_bool cancelled{false};
        auto result=prepare(path,"[1,2,3]",cancelled); QVERIFY(result);
        QCOMPARE(contents(path),QByteArray("original")); QCOMPARE(temporaries(directory).size(),1);
        QVERIFY(result->publish(true)); QCOMPARE(contents(path),QByteArray("[1,2,3]"));
        QVERIFY(!result->publish(true)); result.reset(); QVERIFY(temporaries(directory).isEmpty());
    }
    void abandonedPreparedFileIsCleanedWithoutChangingDestination() {
        QTemporaryDir directory; const auto path=directory.filePath("existing.txt");
        QVERIFY(writeFile(path,"original")); std::atomic_bool cancelled{false};
        auto result=prepare(path,"replacement",cancelled); QVERIFY(result); QCOMPARE(temporaries(directory).size(),1);
        result.reset(); QCOMPARE(contents(path),QByteArray("original")); QVERIFY(temporaries(directory).isEmpty());
    }
    void readonlyDestinationDoesNotMakeCancelledTemporaryUndeletable() {
        QTemporaryDir directory; const auto path=directory.filePath("readonly.txt");
        QVERIFY(writeFile(path,"original"));
        const auto cleanup=qScopeGuard([&] { QFile::setPermissions(path,QFile::ReadOwner|QFile::WriteOwner); });
        QVERIFY(QFile::setPermissions(path,QFile::ReadOwner|QFile::ReadUser)); std::atomic_bool cancelled{false};
        auto result=prepare(path,"replacement",cancelled); QVERIFY(result);
        result.reset(); QCOMPARE(contents(path),QByteArray("original")); QVERIFY(temporaries(directory).isEmpty());
    }
    void newlyAppearedDestinationCannotBeOverwrittenWithoutConfirmation() {
        QTemporaryDir directory; const auto path=directory.filePath("new.txt"); std::atomic_bool cancelled{false};
        auto result=prepare(path,"downloaded bytes",cancelled); QVERIFY(result); QVERIFY(!QFileInfo::exists(path));
        QVERIFY(writeFile(path,"created by someone else"));
        QVERIFY(!result->publish(false)); QCOMPARE(contents(path),QByteArray("created by someone else"));
        result.reset(); QVERIFY(temporaries(directory).isEmpty());
    }
    void nativePublicationFailureDoesNotDeleteTheExistingDestination() {
        QTemporaryDir directory; const auto path=directory.filePath("existing.txt"); std::atomic_bool cancelled{false};
        QVERIFY(writeFile(path,"original")); auto result=prepare(path,"replacement",cancelled); QVERIFY(result);
        // An incompatible destination is a real native rename failure on Windows
        // and POSIX; no delete-first/copy fallback is permitted.
        QVERIFY(QFile::remove(path)); QVERIFY(QDir().mkdir(path)); QVERIFY(writeFile(path+"/original.txt","directory contents"));
        QVERIFY(!result->publish(true)); QVERIFY(QFileInfo(path).isDir());
        QCOMPARE(contents(path+"/original.txt"),QByteArray("directory contents")); result.reset(); QVERIFY(temporaries(directory).isEmpty());
    }
    void invalidParentAndPreCancelledRequestsNeverCreateTemporaryFiles() {
        QTemporaryDir directory; std::atomic_bool cancelled{false};
        QVERIFY(!prepare(directory.filePath("missing/child"),"bytes",cancelled));
        cancelled.store(true); QVERIFY(!prepare(directory.filePath("cancelled.txt"),"bytes",cancelled));
        QVERIFY(temporaries(directory).isEmpty()); QVERIFY(!QFileInfo::exists(directory.filePath("cancelled.txt")));
    }
    void zeroByteDownloadIsSyncedAndPublished() {
        QTemporaryDir directory; const auto path=directory.filePath("empty.txt"); std::atomic_bool cancelled{false};
        auto result=prepare(path,{},cancelled); QVERIFY(result); QVERIFY(result->publish(false));
        QVERIFY(QFileInfo::exists(path)); QCOMPARE(QFileInfo(path).size(),0); QVERIFY(temporaries(directory).isEmpty());
    }
};
QTEST_GUILESS_MAIN(PreparedDownloadTests)
#include "prepared_download_tests.moc"
