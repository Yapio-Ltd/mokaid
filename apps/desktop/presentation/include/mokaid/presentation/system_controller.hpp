#pragma once
#include <QObject>
#include <QSettings>
#include <QVariantMap>
#include <QUrl>
namespace mokaid::desktop {
class SystemController final : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool reducedMotion READ reducedMotion WRITE setReducedMotion NOTIFY changed)
    Q_PROPERTY(bool softwareWeb READ softwareWeb WRITE setSoftwareWeb NOTIFY changed)
    Q_PROPERTY(QString quality READ quality WRITE setQuality NOTIFY changed)
    Q_PROPERTY(QString version READ version CONSTANT)
    Q_PROPERTY(QString productName READ productName CONSTANT)
    Q_PROPERTY(QString assetRoot READ assetRoot CONSTANT)
    Q_PROPERTY(QString error READ error NOTIFY changed)
public:
    explicit SystemController(QString assets, QObject* parent = nullptr);
    bool reducedMotion() const { return settings_.value("accessibility/reducedMotion", false).toBool(); }
    bool softwareWeb() const { return settings_.value("web/software", false).toBool(); }
    QString quality() const { return settings_.value("graphics/quality", "auto").toString(); }
    QString version() const;
    QString productName() const;
    QString assetRoot() const { return assets_; }
    QString error() const { return error_; }
    void setReducedMotion(bool value);
    void setSoftwareWeb(bool value);
    void setQuality(const QString& value);
    Q_INVOKABLE bool exportDiagnostics(const QUrl& destination, const QVariantMap& graphics, const QVariantMap& presentation = {});
    Q_INVOKABLE void openBrowser(const QUrl& destination);
signals:
    void changed();
private:
    QSettings settings_;
    QString assets_, error_;
};
}
