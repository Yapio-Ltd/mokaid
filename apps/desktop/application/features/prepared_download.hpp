#pragma once

#include <QByteArray>
#include <QString>
#include <atomic>
#include <functional>
#include <memory>

class QFileDevice;

namespace mokaid::desktop::detail {
// Internal filesystem boundary. Preparation may block and belongs on the writer
// thread; publication is a same-directory metadata operation, never a copy/flush.
class PreparedDownload final {
    class ConstructionKey {
        friend class PreparedDownload;
        ConstructionKey() = default;
    };
public:
    using Synchronize = std::function<bool(QFileDevice&)>;
    static std::shared_ptr<PreparedDownload> prepare(const QString& destination,
        const QByteArray& bytes, const std::atomic_bool& cancelled,
        const Synchronize& synchronize = synchronizeFile);
    static bool synchronizeFile(QFileDevice& file);
    PreparedDownload(ConstructionKey, QString temporary, QString destination);
    ~PreparedDownload();
    PreparedDownload(const PreparedDownload&) = delete;
    PreparedDownload& operator=(const PreparedDownload&) = delete;

    // Call only after validating the transaction and destination on its owner
    // thread. New destinations cannot overwrite a file that appeared meanwhile.
    // Existing destinations were explicitly confirmed by the native Save dialog.
    bool publish(bool replaceExisting);

private:
    QString temporary_, destination_;
    bool published_{};
};
}
