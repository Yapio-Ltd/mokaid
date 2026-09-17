#include <mokaid/preview/native_file_preview.hpp>

namespace mokaid::desktop {

struct NativeFilePreview::Private {};

NativeFilePreview::NativeFilePreview() = default;
NativeFilePreview::~NativeFilePreview() = default;

bool NativeFilePreview::available() noexcept { return false; }
bool NativeFilePreview::open(const QUrl&, const QString&) { return false; }
void NativeFilePreview::clear() {}

} // namespace mokaid::desktop
