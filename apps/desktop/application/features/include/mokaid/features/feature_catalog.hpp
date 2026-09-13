#pragma once
#include <mokaid/core/policy.hpp>
#include <QJsonObject>
#include <QList>
#include <QString>
#include <QVariantList>
#include <QVariantMap>

namespace mokaid::desktop {
struct FeatureAction {
    QString id, title, method, path;
    bool selection{}, destructive{};
    QVariantList fields;
    QVariantMap defaults;
};
struct FeatureDescriptor {
    QString id, title, section, icon, path, detailPath, collectionKey;
    core::Scope scope{core::Scope::workspace};
    QList<FeatureAction> actions;
    bool hidden{}, paginated{};
};
const QList<FeatureDescriptor>& featureCatalog();
const FeatureDescriptor* findFeature(const QString& id);
QVariantList extractFeatureRecords(const QJsonObject& response, const QString& collectionKey = {});
QString featureRecordId(const QVariantMap& record);
QString featureRecordTitle(const QVariantMap& record);
QString featureRecordSubtitle(const QVariantMap& record);
}
