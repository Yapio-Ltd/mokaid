#pragma once
#include <mokaid/application/session_controller.hpp>
#include <QTimer>
#include <QVariantList>

namespace mokaid::desktop {
// Workspace-owned generation jobs survive closing the creation dialog. Provider
// credentials never reach the desktop; every operation uses the authenticated API.
class AvatarGenerationController final : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList catalog READ catalog NOTIFY changed)
    Q_PROPERTY(QVariantList generations READ generations NOTIFY changed)
    Q_PROPERTY(QVariantMap current READ current NOTIFY changed)
    Q_PROPERTY(QString error READ error NOTIFY changed)
    Q_PROPERTY(bool submitting READ submitting NOTIFY changed)
    Q_PROPERTY(bool refreshing READ refreshing NOTIFY changed)
    Q_PROPERTY(bool online READ online NOTIFY changed)
public:
    AvatarGenerationController(ApiClient&, SessionController&, QObject* parent = nullptr);
    ~AvatarGenerationController() override;
    QVariantList catalog() const { return catalog_; }
    QVariantList generations() const { return generations_; }
    QVariantMap current() const { return current_; }
    QString error() const { return error_; }
    bool submitting() const { return submitting_; }
    bool refreshing() const { return refreshing_; }
    bool online() const { return api_.context().online; }
    Q_INVOKABLE void refresh();
    Q_INVOKABLE void generateText(const QString& prompt, const QString& name = {});
    Q_INVOKABLE void generateImage(const QUrl& file, const QString& name = {});
    Q_INVOKABLE void selectGeneration(const QString& id);
    Q_INVOKABLE void refreshCurrent();
    Q_INVOKABLE void clearCurrent();
signals:
    void changed();
private:
    void syncContext();
    void accept(const QJsonObject&);
    void submit(const QJsonObject&, const QUrl& file = {});
    bool available();
    ApiClient& api_;
    QVariantList catalog_, generations_;
    QVariantMap current_;
    QString error_;
    QTimer poll_;
    QObject listOwner_, submitOwner_, pollOwner_;
    quint64 contextGeneration_{}, epoch_{};
    bool submitting_{}, refreshing_{}, polling_{};
};
}
