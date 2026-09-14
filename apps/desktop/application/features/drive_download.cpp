#include <mokaid/features/drive_download.hpp>
#include "prepared_download.hpp"
#include <QDir>
#include <QDateTime>
#include <QFileInfo>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QUuid>

namespace mokaid::desktop {
namespace {
constexpr qsizetype maximumDownloadBytes = 32 * 1024 * 1024;
struct DestinationStamp {
    bool exists;
    qint64 size;
    QDateTime modified, created;
    explicit DestinationStamp(const QFileInfo& file)
        : exists(file.exists()),size(file.size()),modified(file.lastModified()),created(file.birthTime()) {}
    bool matches(const QFileInfo& file) const {
        return !file.isSymLink() && file.exists()==exists
            && (!exists || (file.size()==size && file.lastModified()==modified && file.birthTime()==created));
    }
};
}
DriveDownload::DriveDownload(ApiClient& api, QObject* parent) : QObject(parent), api_(api) {
    writer_.setMaxThreadCount(1);
}
DriveDownload::~DriveDownload() {
    if (cancelled_) cancelled_->store(true);
    // Interactive cancellation never waits. Final object destruction may wait
    // for an OS sync already in flight; joining keeps queued callbacks safe.
    api_.cancelRequests(this); writer_.waitForDone();
}
QString DriveDownload::safeFileName(QString name) {
    // Bound the normalization work even for an unexpectedly huge API name.
    name = name.section(QRegularExpression("[/\\\\]"), -1).left(1024);
    QString safe;
    for (const auto ch : name) {
        if (ch.category() == QChar::Other_Control || ch.category() == QChar::Other_Format) continue;
        safe += QStringLiteral("<>:\"/\\|?*").contains(ch) ? QChar('_') : ch;
    }
    safe = safe.trimmed();
    while (safe.endsWith('.') || safe.endsWith(' ')) safe.chop(1);
    while (safe.toUtf8().size() > 180) safe.chop(safe.back().isLowSurrogate() ? 2 : 1);
    while (safe.endsWith('.') || safe.endsWith(' ')) safe.chop(1);
    if (safe.isEmpty()) safe = "download";
    if (QRegularExpression("^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\\.|$)", QRegularExpression::CaseInsensitiveOption).match(safe).hasMatch()) safe.prepend('_');
    return safe;
}
bool DriveDownload::current(const QString& transaction) const {
    const auto& context = api_.context();
    return !transaction.isEmpty() && transaction == transaction_ && cancelled_ && !cancelled_->load()
        && context.generation == generation_ && context.authenticated && context.online
        && QString::fromStdString(context.user_id) == user_ && QString::fromStdString(context.workspace_id) == workspace_;
}
void DriveDownload::request(const QVariantMap& record) {
    reset();
    const auto id = record.value("id").toString();
    if (!core::mayRequest(api_.context(), core::Scope::workspace, false) || !api_.context().online
        || record.value("kind") != "file" || record.value("status") != "active"
        || !QRegularExpression("^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$").match(id).hasMatch()) {
        fail("Select an active file while connected to its workspace."); return;
    }
    if (record.value("size_bytes").toLongLong() > maximumDownloadBytes) {
        fail("Native downloads are limited to 32 MiB. This file was not downloaded."); return;
    }
    const auto& context = api_.context();
    generation_ = context.generation; user_ = QString::fromStdString(context.user_id); workspace_ = QString::fromStdString(context.workspace_id);
    transaction_ = QUuid::createUuid().toString(QUuid::WithoutBraces);
    cancelled_ = std::make_shared<std::atomic_bool>(false);
    path_ = "/api/drive/" + id + "/raw";
    auto directory = QStandardPaths::writableLocation(QStandardPaths::DownloadLocation);
    if (directory.isEmpty()) directory = QDir::homePath();
    emit changed();
    emit saveRequested(transaction_, QUrl::fromLocalFile(QDir(directory).filePath(safeFileName(record.value("name").toString()))));
}
void DriveDownload::save(const QString& transaction, const QUrl& destination) {
    if (!current(transaction) || busy_) return;
    const QFileInfo target(destination.toLocalFile());
    if (!destination.isLocalFile() || !destination.host().isEmpty() || !destination.userInfo().isEmpty()
        || destination.hasQuery() || destination.hasFragment() || !target.isAbsolute() || target.fileName().isEmpty()
        || target.isDir() || target.isSymLink()) {
        fail("Choose a local file, not a directory, network location or symbolic link."); return;
    }
    const DestinationStamp stamp(target);
    const auto requestPath = path_;
    const auto cancellation = cancelled_;
    busy_ = true; error_.clear(); status_ = "Downloading · up to 32 MiB"; emit changed();
    if (!current(transaction)) { cancel(transaction); return; }
    api_.getBytes(requestPath, core::Scope::workspace, this, [this, transaction, destination, stamp, cancellation](ApiResponse response) {
        if (!current(transaction)) { cancel(transaction); return; }
        if (!response.ok()) { fail(response.error); return; }
        if (response.bytes.size() > maximumDownloadBytes) { fail("Native downloads are limited to 32 MiB. The destination was not changed."); return; }
        status_ = "Saving…"; emit changed();
        if (!current(transaction)) { cancel(transaction); return; }
        // Writing, Qt flushing, fsync/FlushFileBuffers and closing all happen on
        // this bounded worker. No QFile/QObject changes thread ownership.
        writer_.start([this, transaction, destination, stamp, cancellation, bytes = std::move(response.bytes)] {
            auto file = detail::PreparedDownload::prepare(destination.toLocalFile(), bytes, *cancellation);
            if (!file) {
                QMetaObject::invokeMethod(this, [this, transaction] {
                    if (current(transaction)) fail("The file could not be saved. Check permissions and free disk space; the destination was not changed.");
                    else cancel(transaction);
                }, Qt::QueuedConnection);
                return;
            }
            QMetaObject::invokeMethod(this, [this, transaction, destination, stamp, file = std::move(file)] {
                if (!current(transaction)) { cancel(transaction); return; }
                status_ = "Finalizing…"; emit changed();
                // Signals above may cancel/change context. No signal, event
                // processing or worker callback occurs between these guards and
                // native metadata publication on the owner (GUI) thread.
                if (!current(transaction)) { cancel(transaction); return; }
                if (!stamp.matches(QFileInfo(destination.toLocalFile()))) {
                    fail("The destination changed after it was chosen. Select it again to confirm replacement."); return;
                }
                if (!file->publish(stamp.exists)) { fail("The file could not be committed. The destination was not changed."); return; }
                busy_ = false; transaction_.clear(); status_ = "File saved."; emit changed();
            }, Qt::QueuedConnection);
        });
    });
}
void DriveDownload::cancel(const QString& transaction) {
    if (!transaction.isEmpty() && transaction != transaction_) return;
    if (cancelled_) cancelled_->store(true);
    api_.cancelRequests(this); transaction_.clear(); busy_ = false; status_.clear(); emit changed();
}
void DriveDownload::reset() { cancel(); error_.clear(); emit changed(); }
void DriveDownload::cancelForConnectionLoss() {
    const bool affected = !transaction_.isEmpty();
    cancel();
    if (affected) { error_ = "Download canceled: connection lost. Destination unchanged."; emit changed(); }
}
void DriveDownload::fail(QString message) { cancel(); error_ = std::move(message); emit changed(); }
}
