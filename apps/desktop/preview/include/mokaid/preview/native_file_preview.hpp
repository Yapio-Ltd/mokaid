#pragma once

#include <QString>
#include <QUrl>

#include <memory>

namespace mokaid::desktop {

// Optional system preview for an already downloaded, regular local file.
// Use on the GUI thread. The caller owns the file and must clear the preview
// before replacing or deleting it. Unsupported platforms return false.
class NativeFilePreview final {
public:
    NativeFilePreview();
    ~NativeFilePreview();

    NativeFilePreview(const NativeFilePreview&) = delete;
    NativeFilePreview& operator=(const NativeFilePreview&) = delete;
    NativeFilePreview(NativeFilePreview&&) = delete;
    NativeFilePreview& operator=(NativeFilePreview&&) = delete;

    static bool available() noexcept;
    bool open(const QUrl& localFile, const QString& title = {});
    void clear();

private:
    struct Private;
    std::unique_ptr<Private> d_;
};

} // namespace mokaid::desktop
