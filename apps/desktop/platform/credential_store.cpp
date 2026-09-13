#include <mokaid/platform/credential_store.hpp>
#include <utility>
#ifdef __APPLE__
#include <Security/Security.h>
#include <CoreFoundation/CoreFoundation.h>
#elif defined(_WIN32)
#define NOMINMAX
#include <windows.h>
#include <wincred.h>
#endif
namespace mokaid::desktop {
CredentialStore::CredentialStore(QString service) : service_(std::move(service)) {}
#ifdef __APPLE__
namespace {
struct CFHolder {
    CFTypeRef value{};
    ~CFHolder() { if (value) CFRelease(value); }
    CFHolder(const CFHolder&) = delete;
    CFHolder& operator=(const CFHolder&) = delete;
    explicit CFHolder(CFTypeRef v) : value(v) {}
};
CFStringRef stringRef(const QString& value) {
    auto utf8 = value.toUtf8();
    return CFStringCreateWithBytes(nullptr, reinterpret_cast<const UInt8*>(utf8.constData()), utf8.size(), kCFStringEncodingUTF8, false);
}
CFMutableDictionaryRef queryFor(CFStringRef service, CFStringRef account) {
    auto q = CFDictionaryCreateMutable(nullptr, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(q, kSecClass, kSecClassGenericPassword);
    CFDictionarySetValue(q, kSecAttrService, service);
    CFDictionarySetValue(q, kSecAttrAccount, account);
    return q;
}
}
#endif
std::optional<QByteArray> CredentialStore::read(const QString& account) const {
#ifdef __APPLE__
    CFHolder service(stringRef(service_)), name(stringRef(account));
    auto q = queryFor(static_cast<CFStringRef>(service.value), static_cast<CFStringRef>(name.value));
    CFHolder holder(q);
    CFDictionarySetValue(q, kSecReturnData, kCFBooleanTrue);
    CFDictionarySetValue(q, kSecMatchLimit, kSecMatchLimitOne);
    CFTypeRef result{};
    if (SecItemCopyMatching(q, &result) != errSecSuccess) return std::nullopt;
    CFHolder data(result);
    const auto bytes = static_cast<CFDataRef>(result);
    return QByteArray(reinterpret_cast<const char*>(CFDataGetBytePtr(bytes)), CFDataGetLength(bytes));
#elif defined(_WIN32)
    auto target = (service_ + "/" + account).toStdWString();
    PCREDENTIALW credential{};
    if (!CredReadW(target.c_str(), CRED_TYPE_GENERIC, 0, &credential)) return std::nullopt;
    QByteArray result(reinterpret_cast<const char*>(credential->CredentialBlob), credential->CredentialBlobSize);
    CredFree(credential);
    return result;
#else
    Q_UNUSED(account);
    return std::nullopt;
#endif
}
bool CredentialStore::write(const QString& account, const QByteArray& value) const {
#ifdef __APPLE__
    CFHolder service(stringRef(service_)), name(stringRef(account));
    auto q = queryFor(static_cast<CFStringRef>(service.value), static_cast<CFStringRef>(name.value));
    CFHolder holder(q);
    CFHolder data(CFDataCreate(nullptr, reinterpret_cast<const UInt8*>(value.constData()), value.size()));
    auto changes = CFDictionaryCreateMutable(nullptr, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFHolder updates(changes);
    CFDictionarySetValue(changes, kSecValueData, data.value);
    auto status = SecItemUpdate(q, changes);
    if (status == errSecItemNotFound) {
        CFDictionarySetValue(q, kSecValueData, data.value);
        CFDictionarySetValue(q, kSecAttrAccessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly);
        status = SecItemAdd(q, nullptr);
    }
    return status == errSecSuccess;
#elif defined(_WIN32)
    auto target = (service_ + "/" + account).toStdWString();
    auto user = account.toStdWString();
    CREDENTIALW c{};
    c.Type = CRED_TYPE_GENERIC;
    c.TargetName = target.data();
    c.UserName = user.data();
    c.CredentialBlob = reinterpret_cast<LPBYTE>(const_cast<char*>(value.constData()));
    c.CredentialBlobSize = static_cast<DWORD>(value.size());
    c.Persist = CRED_PERSIST_LOCAL_MACHINE;
    return CredWriteW(&c, 0) != 0;
#else
    Q_UNUSED(account); Q_UNUSED(value); return false;
#endif
}
bool CredentialStore::erase(const QString& account) const {
#ifdef __APPLE__
    CFHolder service(stringRef(service_)), name(stringRef(account));
    auto q = queryFor(static_cast<CFStringRef>(service.value), static_cast<CFStringRef>(name.value));
    CFHolder holder(q);
    auto status = SecItemDelete(q);
    return status == errSecSuccess || status == errSecItemNotFound;
#elif defined(_WIN32)
    auto target = (service_ + "/" + account).toStdWString();
    return CredDeleteW(target.c_str(), CRED_TYPE_GENERIC, 0) || GetLastError() == ERROR_NOT_FOUND;
#else
    Q_UNUSED(account); return false;
#endif
}
}
