#pragma once
#include <mokaid/features/record_list_model.hpp>

namespace mokaid::desktop {
bool isSensitiveDisplayField(const QString& key);
QVariantMap publicDisplayRecord(const QVariantMap& record);

// A lazy, one-level-at-a-time inspector. Large collections and long text use
// the same virtualized list; no recursive QML delegate tree or raw JSON dump.
class DetailBrowser final : public QObject {
    Q_OBJECT
    Q_PROPERTY(QAbstractListModel* rows READ rows CONSTANT)
    Q_PROPERTY(QVariantList breadcrumbs READ breadcrumbs NOTIFY changed)
    Q_PROPERTY(QString heading READ heading NOTIFY changed)
    Q_PROPERTY(bool canGoBack READ canGoBack NOTIFY changed)
    Q_PROPERTY(bool available READ available NOTIFY changed)
    Q_PROPERTY(QVariantList deliverables READ deliverables NOTIFY changed)
public:
    explicit DetailBrowser(QObject* parent=nullptr);
    QAbstractListModel* rows() { return &rows_; }
    QVariantList breadcrumbs() const;
    QString heading() const;
    bool canGoBack() const { return !path_.isEmpty(); }
    bool available() const { return !document_.isEmpty(); }
    QVariantList deliverables() const;
    void setDocument(QVariantMap document, QString context, QString label, QString sourcePage, QString collectionHint={});
    Q_INVOKABLE void enter(const QString& rowId);
    Q_INVOKABLE void goBack();
    Q_INVOKABLE void goTo(int depth);
    Q_INVOKABLE void openReference(const QString& rowId);
    Q_INVOKABLE void openFile(const QString& rowId);
signals:
    void changed();
    void referenceRequested(QString page, QString id);
    void deliveryRequested(QVariantMap file);
private:
    QVariant currentValue() const;
    void rebuild();
    QVariantMap makeRow(const QString& key,const QVariant& value,bool array) const;
    QString referencePage(const QString& key,bool collection) const;
    QVariantMap document_;
    QString context_, label_, sourcePage_, collectionHint_;
    QStringList path_;
    RecordListModel rows_;
};
}
