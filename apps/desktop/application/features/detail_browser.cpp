#include <mokaid/features/detail_browser.hpp>
#include <mokaid/features/feature_catalog.hpp>
#include <QRegularExpression>
#include <QSet>
#include <QUrl>

namespace mokaid::desktop {
namespace {
bool object(const QVariant& value) { return value.metaType().id()==QMetaType::QVariantMap; }
bool array(const QVariant& value) { return value.metaType().id()==QMetaType::QVariantList || value.metaType().id()==QMetaType::QStringList; }
QString label(QString key) { key.replace('_',' '); if (!key.isEmpty()) key[0]=key[0].toUpper(); return key; }
QString textValue(const QVariant& value) {
    if (!value.isValid() || value.isNull()) return QStringLiteral("Not set");
    if (value.metaType().id()==QMetaType::Bool) return value.toBool()?QStringLiteral("Yes"):QStringLiteral("No");
    return value.toString();
}
QString rowPath(const QStringList& parent,const QString& key) {
    QStringList result; for (const auto& part : parent) result.append(QString::fromLatin1(QUrl::toPercentEncoding(part)));
    result.append(QString::fromLatin1(QUrl::toPercentEncoding(key))); return result.join('/');
}
bool idAllowed(const QString& id) { return QRegularExpression(QStringLiteral("^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$")).match(id).hasMatch(); }
int visibleFields(const QVariantMap& value) { int count=0; for (auto it=value.begin();it!=value.end();++it) if (!isSensitiveDisplayField(it.key())) ++count; return count; }
}
bool isSensitiveDisplayField(const QString& key) {
    auto normalized=key.toLower(); normalized.remove(QRegularExpression("[^a-z0-9]"));
    static const QSet<QString> exact{"token","accesstoken","refreshtoken","idtoken","sessiontoken","tokenhash","authorization","authorizationheader","proxyauthorization","cookie","cookies","setcookie","apikey","privatekey","signingkey","encryptionkey","codeverifier","pkceverifier","clientassertion"};
    return exact.contains(normalized) || normalized.contains("password") || normalized.contains("secret") || normalized.contains("credential")
        || normalized.endsWith("token") || normalized.endsWith("apikey") || normalized.endsWith("privatekey");
}
QVariantMap publicDisplayRecord(const QVariantMap& record) {
    QVariantMap result;
    for (auto it=record.begin();it!=record.end();++it) {
        // Nested data is available through DetailBrowser, which filters each
        // level before display. Never hand unfiltered nested objects to QML.
        if (!isSensitiveDisplayField(it.key()) && !object(it.value()) && !array(it.value())) result.insert(it.key(),it.value());
    }
    return result;
}
DetailBrowser::DetailBrowser(QObject* parent):QObject(parent),rows_(this) {}
void DetailBrowser::setDocument(QVariantMap document,QString context,QString name,QString sourcePage,QString collectionHint) {
    if (document_==document && context_==context && label_==name && sourcePage_==sourcePage && collectionHint_==collectionHint) return;
    if (context_!=context || label_!=name) path_.clear();
    document_=std::move(document); context_=std::move(context); label_=std::move(name); sourcePage_=std::move(sourcePage); collectionHint_=std::move(collectionHint);
    while (!path_.isEmpty() && !currentValue().isValid()) path_.removeLast();
    rebuild();
}
QVariant DetailBrowser::currentValue() const {
    QVariant result=document_;
    for (const auto& part : path_) {
        if (object(result)) { if (isSensitiveDisplayField(part)) return {}; result=result.toMap().value(part); }
        else if (array(result)) { bool valid=false; const auto index=part.toInt(&valid); const auto list=result.toList(); if (!valid || index<0 || index>=list.size()) return {}; result=list[index]; }
        else return {};
    }
    return result;
}
QVariantList DetailBrowser::breadcrumbs() const {
    QVariantList result{QVariantMap{{"label",label_.isEmpty()?QString("Details"):label_},{"depth",0}}};
    for (qsizetype i=0;i<path_.size();++i) result.append(QVariantMap{{"label",label(path_[i])},{"depth",i+1}});
    return result;
}
QString DetailBrowser::heading() const { return path_.isEmpty()?label_:label(path_.last()); }
QString DetailBrowser::referencePage(const QString& key,bool collection) const {
    auto target=key; if (target=="items") target=collectionHint_;
    if (sourcePage_.startsWith("admin-")) {
        if (target=="user_id" || target=="users" || target=="user") return "admin-users";
        if (target=="workspace_id" || target=="workspaces" || target=="workspace") return "admin-workspaces";
        if (target=="subscription_id" || target=="subscriptions") return "admin-subscriptions";
        if (target=="invoice_id" || target=="invoices") return "admin-invoices";
        return {}; // An operator role does not grant customer-workspace membership.
    }
    if (target=="task_id" || target=="linked_task_id" || target=="tasks") return "tasks";
    if (target=="project_id" || target=="projects") return "projects";
    if (target=="agent_id" || target=="assigned_agent_id" || target=="agent_ids" || target=="agents" || target=="agent") return "agents";
    if (target=="knowledge_id" || target=="knowledge") return "knowledge";
    if (target=="drive_item_id" || target=="drive_folder_id" || target=="drive") return "drive";
    if (collection && target=="members") return "members";
    return {};
}
QVariantMap DetailBrowser::makeRow(const QString& key,const QVariant& value,bool inArray) const {
    const auto map=value.toMap(); const auto list=value.toList();
    auto title=inArray ? featureRecordTitle(map) : label(key);
    if (inArray && (map.isEmpty() || title=="Record")) title=QString("Item %1").arg(key.toInt()+1);
    const auto text=textValue(value);
    const bool container=object(value)||array(value), expandable=(container || text.size()>240) && path_.size()<32;
    auto summary=object(value)?QString("%1 fields").arg(visibleFields(map)):array(value)?QString("%1 items").arg(list.size()):text.left(240);
    if (!summary.isEmpty() && summary.back().isHighSurrogate()) summary.chop(1);
    if (container && !expandable) summary+=" · maximum inspection depth reached";
    QVariantMap row{{"id",rowPath(path_,key)},{"title",title},{"nodeKey",key},{"text",summary},{"expandable",expandable},{"container",container},
        {"status",map.value("status")},{"referencePage",QString{}},{"referenceId",QString{}},{"fileAvailable",false}};
    auto reference=referencePage(inArray && !path_.isEmpty()?path_.last():key,inArray);
    auto id=object(value)?map.value("id",map.value("member_id")).toString():value.toString();
    if (!reference.isEmpty() && idAllowed(id)) { row.insert("referencePage",reference); row.insert("referenceId",id); }
    const auto fileId=map.value("drive_item_id",map.value("id")).toString();
    const bool attachment=path_.contains("attachments") || map.contains("drive_item_id") || sourcePage_=="drive" || collectionHint_=="drive";
    if (attachment && idAllowed(fileId) && !map.value("name").toString().isEmpty() && map.value("kind").toString()!="folder"
        && (map.contains("mime_type") || map.contains("drive_item_id"))) row.insert("fileAvailable",true);
    return row;
}
void DetailBrowser::rebuild() {
    const auto value=currentValue(); QVariantList records;
    if (object(value)) {
        const auto map=value.toMap();
        for (auto it=map.begin();it!=map.end();++it) if (!isSensitiveDisplayField(it.key())) records.append(makeRow(it.key(),it.value(),false));
    } else if (array(value)) {
        const auto list=value.toList();
        for (qsizetype i=0;i<list.size();++i) records.append(makeRow(QString::number(i),list[i],true));
    } else if (value.isValid()) {
        const auto text=textValue(value); constexpr qsizetype chunkSize=4096;
        for (qsizetype i=0;i<text.size();) {
            auto end=qMin(i+chunkSize,text.size());
            if (end<text.size() && text[end-1].isHighSurrogate() && text[end].isLowSurrogate()) --end;
            records.append(QVariantMap{{"id",QString("text-%1").arg(i)},{"title",QString("Text · %1–%2 / %3").arg(i+1).arg(end).arg(text.size())},
                {"text",text.mid(i,end-i)},{"expandable",false},{"container",false},{"referencePage",QString{}},{"referenceId",QString{}},{"fileAvailable",false}});
            i=end;
        }
    }
    rows_.setRecords(std::move(records)); emit changed();
}
void DetailBrowser::enter(const QString& rowId) {
    const auto row=rows_.record(rowId); if (!row.value("expandable").toBool() || path_.size()>=32) return;
    path_.append(row.value("nodeKey").toString()); rebuild();
}
void DetailBrowser::goBack() { if (!path_.isEmpty()) { path_.removeLast(); rebuild(); } }
void DetailBrowser::goTo(int depth) { if (depth<0 || depth>path_.size()) return; while (path_.size()>depth) path_.removeLast(); rebuild(); }
void DetailBrowser::openReference(const QString& rowId) {
    const auto row=rows_.record(rowId); const auto page=row.value("referencePage").toString(), id=row.value("referenceId").toString();
    if (!page.isEmpty() && idAllowed(id)) emit referenceRequested(page,id);
}
void DetailBrowser::openFile(const QString& rowId) {
    const auto row=rows_.record(rowId); if (!row.value("fileAvailable").toBool()) return;
    const auto current=currentValue(); QVariant value;
    if (object(current)) value=current.toMap().value(row.value("nodeKey").toString());
    else if (array(current)) value=current.toList().value(row.value("nodeKey").toInt());
    const auto map=value.toMap(); const auto id=map.value("drive_item_id",map.value("id")).toString();
    if (!idAllowed(id)) return;
    emit deliveryRequested({{"id",id},{"name",map.value("name")},{"mime_type",map.value("mime_type")},{"size_bytes",map.value("size_bytes")}});
}
}
