#include <mokaid/features/record_list_model.hpp>
#include <mokaid/features/feature_catalog.hpp>
#include <mokaid/features/detail_browser.hpp>
#include <QJsonDocument>
#include <QSet>
#include <algorithm>

namespace mokaid::desktop {
RecordListModel::RecordListModel(QObject* parent) : QAbstractListModel(parent) {}
int RecordListModel::rowCount(const QModelIndex& parent) const { return parent.isValid() ? 0 : static_cast<int>(visible_.size()); }
QVariant RecordListModel::data(const QModelIndex& index, int role) const {
    if (!index.isValid() || index.model()!=this || index.column()!=0 || index.row() < 0 || index.row() >= visible_.size()) return {};
    const auto record = visible_.at(index.row()).toMap();
    switch (role) {
    case Record: return publicDisplayRecord(record);
    case RowId: return featureRecordId(record);
    case Title: return featureRecordTitle(record);
    case Subtitle: return featureRecordSubtitle(record);
    case Status: return record.value("status", record.value("indexing_status", record.value("kind")));
    default: return {};
    }
}
QHash<int, QByteArray> RecordListModel::roleNames() const {
    return {{Record,"record"},{RowId,"rowId"},{Title,"title"},{Subtitle,"subtitle"},{Status,"status"}};
}
void RecordListModel::setRecords(QVariantList records) { all_ = std::move(records); reconcile(); }
void RecordListModel::setQuery(const QString& query) { if (query_ == query) return; query_ = query; reconcile(); }
QVariantMap RecordListModel::record(const QString& id) const {
    for (const auto& value : all_) if (featureRecordId(value.toMap()) == id) return value.toMap();
    return {};
}
void RecordListModel::reconcile() {
    QVariantList next;
    QSet<QString> ids;
    for (const auto& value : all_) {
        const auto record = value.toMap();
        const auto id = featureRecordId(record);
        if (ids.contains(id)) continue;
        if (!query_.isEmpty()) {
            const auto text=QString::fromUtf8(QJsonDocument::fromVariant(publicDisplayRecord(record)).toJson(QJsonDocument::Compact));
            if (!text.contains(query_,Qt::CaseInsensitive)) continue;
        }
        ids.insert(id); next.append(record);
    }
    // Preserve delegates and their focus/scroll position on ordinary row updates.
    for (int i = static_cast<int>(visible_.size()) - 1; i >= 0; --i) {
        if (!ids.contains(featureRecordId(visible_[i].toMap()))) {
            beginRemoveRows({}, i, i); visible_.removeAt(i); endRemoveRows();
        }
    }
    for (int i = 0; i < next.size(); ++i) {
        const auto id = featureRecordId(next[i].toMap());
        if (i >= visible_.size() || featureRecordId(visible_[i].toMap()) != id) {
            int found = -1;
            for (int j = i + 1; j < visible_.size(); ++j) if (featureRecordId(visible_[j].toMap()) == id) { found = j; break; }
            if (found >= 0) {
                beginMoveRows({}, found, found, {}, i); visible_.move(found, i); endMoveRows();
            } else {
                beginInsertRows({}, i, i); visible_.insert(i, next[i]); endInsertRows();
            }
        }
        if (visible_[i] != next[i]) {
            visible_[i] = next[i]; emit dataChanged(index(i), index(i));
        }
    }
}
}
