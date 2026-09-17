#pragma once
#include <QByteArray>
#include <QString>
#include <optional>
namespace mokaid::desktop {
class CredentialStorage {
public:
    virtual ~CredentialStorage() = default;
    [[nodiscard]] virtual std::optional<QByteArray> read(const QString& account) const = 0;
    [[nodiscard]] virtual bool write(const QString& account, const QByteArray& value) const = 0;
    [[nodiscard]] virtual bool erase(const QString& account) const = 0;
};
class CredentialStore final : public CredentialStorage {
public:
    explicit CredentialStore(QString service);
    [[nodiscard]] std::optional<QByteArray> read(const QString& account) const override;
    [[nodiscard]] bool write(const QString& account, const QByteArray& value) const override;
    [[nodiscard]] bool erase(const QString& account) const override;
private:
    QString service_;
};
}
