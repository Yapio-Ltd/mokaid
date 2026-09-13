#pragma once
#include <QByteArray>
#include <QString>
#include <optional>
namespace mokaid::desktop {
class CredentialStore final {
public:
    explicit CredentialStore(QString service);
    [[nodiscard]] std::optional<QByteArray> read(const QString& account) const;
    [[nodiscard]] bool write(const QString& account, const QByteArray& value) const;
    [[nodiscard]] bool erase(const QString& account) const;
private:
    QString service_;
};
}
