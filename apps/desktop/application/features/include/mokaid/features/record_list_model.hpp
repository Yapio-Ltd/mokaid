#pragma once
#include <QAbstractListModel>
#include <QVariantList>

namespace mokaid::desktop {
class RecordListModel final : public QAbstractListModel {
    Q_OBJECT
public:
    enum Role { Record = Qt::UserRole + 1, RowId, Title, Subtitle, Status };
    explicit RecordListModel(QObject* parent = nullptr);
    int rowCount(const QModelIndex& parent = {}) const override;
    QVariant data(const QModelIndex& index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;
    void setRecords(QVariantList records);
    void setQuery(const QString& query);
    QVariantMap record(const QString& id) const;
    Q_INVOKABLE QVariantList previewFiles() const;
    const QVariantList& allRecords() const { return all_; }
    const QVariantList& visibleRecords() const { return visible_; }
private:
    void reconcile();
    QVariantList all_, visible_;
    QString query_;
};
}
