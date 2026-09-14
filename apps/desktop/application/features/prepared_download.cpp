#include "prepared_download.hpp"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QTemporaryFile>
#include <QThread>
#include <algorithm>
#include <cerrno>
#include <utility>

#ifdef Q_OS_WIN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <io.h>
#else
#include <cstdio>
#include <unistd.h>
#endif

namespace mokaid::desktop::detail {
PreparedDownload::PreparedDownload(ConstructionKey, QString temporary, QString destination)
    : temporary_(std::move(temporary)), destination_(std::move(destination)) {}

PreparedDownload::~PreparedDownload() {
    // A failed/cancelled preparation never owns the destination. After POSIX
    // link publication only this extra temporary link can remain to be removed.
    if (!temporary_.isEmpty()) QFile::remove(temporary_);
}

bool PreparedDownload::synchronizeFile(QFileDevice& file) {
    if (!file.flush()) return false;
#ifdef Q_OS_WIN
    // Qt may fail to allocate a CRT descriptor for an otherwise open native
    // file. Passing -1 to _get_osfhandle invokes MSVC's invalid-parameter handler.
    const auto descriptor = file.handle();
    if (descriptor < 0) return false;
    const auto handle = _get_osfhandle(descriptor);
    return handle != -1 && FlushFileBuffers(reinterpret_cast<HANDLE>(handle)) != 0;
#else
    int result;
    do { result = ::fsync(file.handle()); } while (result == -1 && errno == EINTR);
    return result == 0;
#endif
}

std::shared_ptr<PreparedDownload> PreparedDownload::prepare(const QString& destination,
    const QByteArray& bytes, const std::atomic_bool& cancelled, const Synchronize& synchronize) {
    if (QThread::isMainThread() || cancelled.load()) return {};
    // QTemporaryFile creates an exclusive, private file in the destination's
    // directory. There is deliberately no cross-volume/system-temp fallback.
    QTemporaryFile file(QDir(QFileInfo(destination).absolutePath()).filePath(".mokaid-download-XXXXXX"));
    if (!file.open()) return {};
    // Materialize the name before close (Linux may initially use O_TMPFILE).
    const auto temporary = file.fileName();
    if (temporary.isEmpty()) return {};
    for (qsizetype offset = 0; offset < bytes.size();) {
        if (cancelled.load()) return {};
        const auto count = std::min<qsizetype>(256 * 1024, bytes.size() - offset);
        if (file.write(bytes.constData() + offset, count) != count) return {};
        offset += count;
    }
    // Keep existing POSIX permissions when replacing. Do not copy Windows'
    // readonly attribute onto the temporary (it would prevent cancellation
    // cleanup); native replacement of a readonly destination fails untouched.
    // Ownership, ACLs and extended attributes are not cloned.
#ifndef Q_OS_WIN
    const QFileInfo target(destination);
    if (target.exists() && !file.setPermissions(target.permissions())) return {};
#endif
    if (cancelled.load() || !synchronize(file) || cancelled.load()) return {};
    // Qt close and destruction (which closes QTemporaryFile's retained native
    // handle) both occur before prepare returns, entirely on this worker.
    // synchronizeFile already flushed Qt's buffer before syncing the OS handle.
    file.close();
    if (file.error() != QFileDevice::NoError || cancelled.load()) return {};
    auto prepared = std::make_shared<PreparedDownload>(ConstructionKey{}, temporary, destination);
    file.setAutoRemove(false);
    return prepared;
}

bool PreparedDownload::publish(bool replaceExisting) {
    if (published_ || temporary_.isEmpty()) return false;
#ifdef Q_OS_WIN
    // Unlike ReplaceFileW without a backup, a failed MoveFileExW does not have
    // documented failure modes that remove the old destination. Never request
    // COPY_ALLOWED or WRITE_THROUGH: this is a same-volume rename, not disk I/O
    // proportional to the file size. Use extended paths for native UTF-16 names.
    const auto nativePath = [](const QString& path) {
        const auto native = QDir::toNativeSeparators(QFileInfo(path).absoluteFilePath());
        return native.startsWith("\\\\?\\") ? native : QStringLiteral("\\\\?\\") + native;
    };
    const auto source = nativePath(temporary_), destination = nativePath(destination_);
    if (!MoveFileExW(reinterpret_cast<LPCWSTR>(source.utf16()), reinterpret_cast<LPCWSTR>(destination.utf16()),
                    replaceExisting ? MOVEFILE_REPLACE_EXISTING : 0)) return false;
    temporary_.clear();
#else
    const auto source = QFile::encodeName(temporary_), destination = QFile::encodeName(destination_);
    if (replaceExisting) {
        if (::rename(source.constData(), destination.constData()) != 0) return false;
        temporary_.clear();
    } else {
#ifdef Q_OS_MACOS
        // macOS's exclusive rename also supports volumes without hard links.
        if (::renamex_np(source.constData(), destination.constData(), RENAME_EXCL) != 0) return false;
        temporary_.clear();
#else
        // link is atomic and refuses EEXIST. QFile::rename's copy fallback would
        // expose partial bytes; rename() alone would silently overwrite a racer.
        if (::link(source.constData(), destination.constData()) != 0) return false;
        if (::unlink(source.constData()) == 0) temporary_.clear();
#endif
    }
#endif
    published_ = true;
    return true;
}
}
