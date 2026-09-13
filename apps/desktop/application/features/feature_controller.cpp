#include <mokaid/features/feature_controller.hpp>
#include <QCryptographicHash>
#include <QDateTime>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonParseError>
#include <QRegularExpression>
#include <QUrlQuery>
#include <QUuid>
#include <limits>

namespace mokaid::desktop {
namespace {
QString identityUser(const ApiClient& api,const SessionController& session) {
    return api.context().authenticated?QString::fromStdString(api.context().user_id):session.user().value("id").toString();
}
QString identityWorkspace(const ApiClient& api,const SessionController& session) {
    return api.context().authenticated?QString::fromStdString(api.context().workspace_id):session.workspaceId();
}
QVariantMap responseDetails(const QJsonObject& response) {
    const auto data = response.contains("data") ? response.value("data") : QJsonValue(response);
    auto detail = data.isObject() ? data.toObject().toVariantMap() : QVariantMap{{"items",data.toVariant()}};
    if (response.contains("meta")) detail.insert("meta",response.value("meta").toVariant());
    if (detail.contains("user") && !detail.contains("id")) {
        const auto user = detail.value("user").toMap();
        if (!user.isEmpty()) for (auto it=user.begin();it!=user.end();++it) if (!detail.contains(it.key())) detail.insert(it.key(),it.value());
    }
    return detail;
}
bool parseField(const QVariantMap& field, const QVariant& value, QJsonValue& parsed, QString& error) {
    const auto key=field.value("key").toString(), type=field.value("type").toString(), label=field.value("label").toString();
    const bool required=field.value("required").toBool();
    if (!value.isValid() || value.isNull() || (value.metaType().id()==QMetaType::QString && value.toString().trimmed().isEmpty())) {
        if (required) { error=label+" is required."; return false; }
        parsed=QJsonValue::Null; return true;
    }
    if (type=="int") {
        bool valid=false; const auto number=value.toLongLong(&valid);
        if (!valid || number<std::numeric_limits<int>::min() || number>std::numeric_limits<int>::max()) { error=label+" must be a whole number."; return false; }
        parsed=static_cast<int>(number);
    } else if (type=="bool") {
        if (value.metaType().id()!=QMetaType::Bool) { error=label+" must be true or false."; return false; }
        parsed=value.toBool();
    } else if (type=="json") {
        if (value.metaType().id()==QMetaType::QVariantMap || value.metaType().id()==QMetaType::QVariantList) parsed=QJsonValue::fromVariant(value);
        else {
            QJsonParseError failure; const auto document=QJsonDocument::fromJson(value.toString().toUtf8(),&failure);
            if (failure.error!=QJsonParseError::NoError || document.isNull()) { error=label+" must contain valid JSON."; return false; }
            parsed=document.isObject()?QJsonValue(document.object()):QJsonValue(document.array());
        }
    } else if (type=="datetime") {
        auto date=QDateTime::fromString(value.toString(),Qt::ISODateWithMs);
        if (!date.isValid()) date=QDateTime::fromString(value.toString(),Qt::ISODate);
        if (!date.isValid()) { error=label+" must be an ISO date and time."; return false; }
        parsed=date.toUTC().toString(Qt::ISODateWithMs);
    } else {
        const auto text=value.toString();
        if (text.size()>65536) { error=label+" is too long."; return false; }
        if (type=="enum" && !field.value("options").toList().contains(text)) { error="Choose a valid "+label.toLower()+"."; return false; }
        if (type=="email" && !QRegularExpression(QStringLiteral("^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$")).match(text).hasMatch()) { error="Enter a valid email address."; return false; }
        if (key=="password" && text.size()<10) { error="Use at least 10 characters for the new password."; return false; }
        parsed=text;
    }
    return true;
}
bool externalUrlAllowed(const QUrl& url) {
    return url.isValid() && url.scheme()=="https" && !url.host().isEmpty() && url.userInfo().isEmpty();
}
}

FeatureController::FeatureController(ApiClient& api, SessionController& session, CacheStore& cache, QObject* parent)
    : QObject(parent),api_(api),session_(session),cache_(cache),records_(this),detailView_(this),searchTimer_(this) {
    connect(this,&FeatureController::changed,this,[this] {
        detailView_.setDocument(details_,currentPage_+":"+selectedId_,detailHeading_.isEmpty()?QString("Overview"):detailHeading_,currentPage_,detailCollection_);
    });
    connect(&detailView_,&DetailBrowser::referenceRequested,this,&FeatureController::openRecord);
    connect(&detailView_,&DetailBrowser::deliveryRequested,this,&FeatureController::openDelivery);
    searchTimer_.setSingleShot(true); searchTimer_.setInterval(250);
    connect(&searchTimer_,&QTimer::timeout,this,&FeatureController::refresh);
    connect(&session_,&SessionController::changed,this,&FeatureController::sessionChanged);
    connect(&session_,&SessionController::established,this,[this] { sessionChanged(); if (!busy_) refresh(); });
    connect(&session_,&SessionController::workspaceChanged,this,&FeatureController::sessionChanged);
    connect(&session_,&SessionController::cleared,this,[this]{clear();contextTag_.clear();currentPage_="office";emit changed();});
    connect(&api_,&ApiClient::onlineChanged,this,[this](bool online) {
        const auto* feature=findFeature(currentPage_);
        if (!online && feature && feature->scope==core::Scope::administration) {
            clear(); currentPage_="office"; fail("Administration requires a verified online session.");
        } else {
            offline_=!online; emit changed();
            if (!online && session_.authenticated() && !busy_ && records_.allRecords().isEmpty()) refresh();
        }
    });
    connect(&api_,&ApiClient::administratorDenied,this,[this] {
        if (const auto* feature=findFeature(currentPage_); feature && feature->scope==core::Scope::administration) {
            clear(); currentPage_="office"; fail("Administrator access is no longer available.");
        }
        emit changed();
    });
    sessionChanged();
}
QVariantList FeatureController::pages() const {
    QVariantList list;
    for (const auto& feature : featureCatalog()) {
        if (feature.scope==core::Scope::administration && !session_.administrator()) continue;
        list.append(QVariantMap{{"id",feature.id},{"title",feature.title},{"section",feature.section},{"icon",feature.icon},{"hidden",feature.hidden}});
    }
    return list;
}
QString FeatureController::title() const { const auto* feature=findFeature(currentPage_); return feature ? feature->title : QString{}; }
QVariantList FeatureController::fields() const { return fieldsForAction("edit"); }
QVariantList FeatureController::fieldsForAction(const QString& id) const {
    const auto* action=findAction(id); if (!action) return {};
    auto fields=action->fields;
    auto data=editDetails_;
    if (selectedId_.isEmpty() && currentPage_!="profile" && currentPage_!="settings") data.clear();
    for (auto& value : fields) {
        auto field=value.toMap(); const auto key=field.value("key").toString();
        QVariant current=action->defaults.value(key);
        if (id=="edit" || currentPage_=="settings" || currentPage_=="profile") {
            if (data.contains(key)) current=data.value(key);
            else if (key=="plan_key") current=data.value("plan").toMap().value("key");
        }
        if (id=="create" && currentPage_=="agent-new" && key=="archetype_key") current=records_.record(selectedId_).value("key");
        field.insert("value",current); field.insert("defaultValue",current); value=field;
    }
    return fields;
}
QVariantList FeatureController::actions() const {
    const auto* feature=findFeature(currentPage_); if (!feature) return {};
    QVariantList list;
    for (const auto& action : feature->actions) {
        const bool hasSelection=!selectedId_.isEmpty();
        list.append(QVariantMap{{"id",action.id},{"title",action.title},{"selection",action.selection},{"destructive",action.destructive},
            {"fields",fieldsForAction(action.id)},{"enabled",!busy_ && (!action.selection || hasSelection) && permitted(*feature,action.method!="GET" && action.method!="DELIVERY")},
            {"confirmation",action.destructive ? QString("%1? This changes live data. Confirm the selected account and workspace before continuing.").arg(action.title) : QString{}}});
    }
    return list;
}
const FeatureAction* FeatureController::findAction(const QString& id) const {
    const auto* feature=findFeature(currentPage_); if (!feature) return nullptr;
    for (const auto& action : feature->actions) if (action.id==id) return &action;
    return nullptr;
}
void FeatureController::clear() {
    ++epoch_; ++detailEpoch_; busy_=false; offline_=false; nextPage_=0; loadingMore_=false;
    api_.cancelRequests(this); pendingSelection_.clear(); detailHeading_.clear(); detailCollection_.clear(); overview_.clear();
    error_.clear(); selectedId_.clear(); details_.clear(); editDetails_.clear(); records_.setRecords({}); retryKeys_.clear(); searchTimer_.stop();
}
void FeatureController::sessionChanged() {
    const auto tag=QString::fromStdString(core::cacheKey(api_.origin().toString().toStdString(),
        identityUser(api_,session_).toStdString(),identityWorkspace(api_,session_).toStdString(),"context"));
    if (tag!=contextTag_ || sessionGeneration_!=api_.context().generation) {
        clear(); contextTag_=tag; sessionGeneration_=api_.context().generation;
        if (!session_.administrator() && currentPage_.startsWith("admin-")) currentPage_="office";
        if (session_.authenticated()) refresh();
    }
    if (!session_.administrator() && currentPage_.startsWith("admin-")) { clear(); currentPage_="office"; }
    emit changed();
}
bool FeatureController::permitted(const FeatureDescriptor& feature,bool mutation) const {
    // A restored vault-backed identity may read its own cached data before a
    // network refresh succeeds. It never authorizes requests or administrator data.
    if (!mutation && !api_.context().online && feature.scope!=core::Scope::administration) {
        return core::mayRequest(api_.context(),feature.scope,false) || (session_.authenticated() && !session_.user().value("id").toString().isEmpty()
            && (feature.scope!=core::Scope::workspace || !session_.workspaceId().isEmpty()));
    }
    return core::mayRequest(api_.context(),feature.scope,mutation);
}
void FeatureController::navigate(const QString& page) {
    pendingSelection_.clear();
    const auto* feature=findFeature(page);
    if (!feature) { fail("This page is not available."); return; }
    if (feature->scope==core::Scope::administration && !session_.administrator()) { fail("Administrator access requires an online, authorized session."); return; }
    clear(); currentPage_=page; search_.clear(); records_.setQuery({}); emit changed(); refresh();
}
void FeatureController::refresh() { if (!busy_) load(1,false); }
void FeatureController::loadMore() { if (nextPage_>0 && !busy_ && !loadingMore_) load(nextPage_,true); }
void FeatureController::load(int page,bool append) {
    const auto* feature=findFeature(currentPage_); if (!feature) return;
    if (!permitted(*feature,false)) { fail(feature->scope==core::Scope::workspace ? "Select a workspace to continue." : "Sign in to continue."); return; }
    auto path=resolvePath(feature->path,{});
    if (path.isEmpty()) { fail("Select a workspace to continue."); return; }
    if (feature->paginated) {
        QUrl url(path); QUrlQuery query(url); query.addQueryItem("page",QString::number(page)); query.addQueryItem("per_page","100");
        if (!search_.isEmpty()) query.addQueryItem("q",search_);
        url.setQuery(query); path=url.toString(QUrl::FullyEncoded);
    }
    const auto epoch=++epoch_, generation=api_.context().generation;
    error_.clear(); busy_=true; loadingMore_=append; emit changed();
    if (!api_.context().online) { readCached(path,epoch,generation,append); return; }
    api_.request("GET",path,{},feature->scope,this,[this,path,epoch,generation,append](ApiResponse response) {
        if (epoch!=epoch_ || generation!=api_.context().generation) return;
        const auto* feature=findFeature(currentPage_); if (!feature || !permitted(*feature,false)) { clear(); emit changed(); return; }
        if (!response.ok()) {
            if (response.networkError && feature->scope!=core::Scope::administration) { readCached(path,epoch,generation,append); return; }
            busy_=false; loadingMore_=false; fail(response.error); return;
        }
        if (feature->scope!=core::Scope::administration) cache_.write(cacheKey(path),response.bytes);
        offline_=false; busy_=false; loadingMore_=false; acceptList(response.json,append); emit changed();
    });
}
void FeatureController::readCached(const QString& path,quint64 epoch,quint64 generation,bool append) {
    const auto* feature=findFeature(currentPage_);
    if (!feature || feature->scope==core::Scope::administration) { clear(); fail("Administration is unavailable offline."); return; }
    cache_.read(cacheKey(path),this,[this,epoch,generation,append](QByteArray bytes) {
        if (epoch!=epoch_ || generation!=api_.context().generation) return;
        busy_=false; loadingMore_=false; offline_=true;
        QJsonParseError error; const auto document=QJsonDocument::fromJson(bytes,&error);
        if (error.error==QJsonParseError::NoError && document.isObject()) { acceptList(document.object(),append); error_="Offline — displaying the last synchronized data."; }
        else { if (!append) records_.setRecords({}); error_="No synchronized data is available for this page yet."; }
        emit changed();
    });
}
void FeatureController::acceptList(const QJsonObject& response,bool append) {
    const auto* feature=findFeature(currentPage_); if (!feature) return;
    auto rows=extractFeatureRecords(response,feature->collectionKey);
    if (append) { auto existing=records_.allRecords(); existing.append(rows); rows=std::move(existing); }
    records_.setRecords(std::move(rows));
    overview_=responseDetails(response);
    const auto meta=response.value("meta").toObject();
    const auto page=meta.value("page").toInt(1), total=meta.value("total_pages").toInt(1);
    nextPage_=feature->paginated && page<total ? page+1 : 0;
    if (!pendingSelection_.isEmpty()) {
        const auto id = pendingSelection_; pendingSelection_.clear(); select(id); return;
    }
    if (selectedId_.isEmpty()) { details_=overview_; editDetails_=details_; detailHeading_="Overview"; detailCollection_.clear(); }
    else if (records_.record(selectedId_).isEmpty() && feature->detailPath.isEmpty()) clearSelection();
    else select(selectedId_);
}
void FeatureController::select(const QString& id) {
    auto record=records_.record(id);
    const auto* target = findFeature(currentPage_);
    if (record.isEmpty() && target && !target->detailPath.isEmpty() && permitted(*target, false)
        && QRegularExpression("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$").match(id).hasMatch()) record.insert("id", id);
    if (record.isEmpty()) { clearSelection(); return; }
    pendingSelection_.clear(); selectedId_=id; details_=record; editDetails_=record; detailHeading_="Record details"; detailCollection_.clear(); error_.clear(); const auto epoch=++detailEpoch_; emit changed();
    const auto* feature=findFeature(currentPage_); if (!feature || feature->detailPath.isEmpty() || !permitted(*feature,false)) return;
    const auto path=resolvePath(feature->detailPath,id,record);
    const auto generation=api_.context().generation;
    if (path.isEmpty()) return;
    const auto apply=[this,epoch,generation,id](const QJsonObject& response) {
        if (epoch!=detailEpoch_ || generation!=api_.context().generation || selectedId_!=id) return;
        const auto expanded=responseDetails(response);
        for (auto it=expanded.begin();it!=expanded.end();++it) details_.insert(it.key(),it.value());
        editDetails_=details_;
        emit changed();
    };
    if (!api_.context().online && feature->scope!=core::Scope::administration) {
        cache_.read(cacheKey(path),this,[apply](QByteArray bytes) { const auto doc=QJsonDocument::fromJson(bytes); if (doc.isObject()) apply(doc.object()); });
        return;
    }
    api_.request("GET",path,{},feature->scope,this,[this,path,epoch,generation,apply](ApiResponse response) {
        if (epoch!=detailEpoch_ || generation!=api_.context().generation) return;
        if (!response.ok()) { clearSelection(); fail(response.error); return; }
        const auto* feature=findFeature(currentPage_);
        if (!feature || !permitted(*feature,false)) return;
        if (feature->scope!=core::Scope::administration) cache_.write(cacheKey(path),response.bytes);
        apply(response.json);
    });
}
void FeatureController::clearSelection() { ++detailEpoch_; pendingSelection_.clear(); selectedId_.clear(); details_.clear(); editDetails_.clear(); emit changed(); }
void FeatureController::showOverview() { clearSelection(); details_=overview_; if (currentPage_=="profile" || currentPage_=="settings") editDetails_=overview_; detailHeading_="Overview"; detailCollection_.clear(); emit changed(); }
void FeatureController::showRecordDetails() { if (selectedId_.isEmpty()) return; ++detailEpoch_; details_=editDetails_; detailHeading_="Record details"; detailCollection_.clear(); emit changed(); }
void FeatureController::openRecord(const QString& page, const QString& id) {
    if (!findFeature(page)) return;
    pendingSelection_.clear(); navigate(page);
    if (currentPage_ != page || id.isEmpty()) return;
    if (busy_) pendingSelection_ = id;
    else select(id);
}
void FeatureController::search(const QString& query) {
    search_=query.left(256); const auto* feature=findFeature(currentPage_);
    if (feature && feature->paginated && api_.context().online) { records_.setQuery({}); searchTimer_.start(); }
    else records_.setQuery(search_);
}
QString FeatureController::cacheKey(const QString& path) const {
    return QString::fromStdString(core::cacheKey(api_.origin().toString().toStdString(),
        identityUser(api_,session_).toStdString(),identityWorkspace(api_,session_).toStdString(),path.toStdString()));
}
QString FeatureController::resolvePath(QString path,const QString& id,const QVariantMap& values) const {
    auto replacements=records_.record(id); if (id==selectedId_) for (auto it=editDetails_.begin();it!=editDetails_.end();++it) replacements.insert(it.key(),it.value());
    for (auto it=values.begin();it!=values.end();++it) replacements.insert(it.key(),it.value());
    replacements.insert("id",id); replacements.insert("workspace",identityWorkspace(api_,session_));
    const QRegularExpression placeholder(QStringLiteral("\\{([a-z_]+)\\}"));
    auto match=placeholder.match(path);
    while (match.hasMatch()) {
        const auto value=replacements.value(match.captured(1)).toString();
        if (value.isEmpty() || value.size()>128 || !QRegularExpression(QStringLiteral("^[A-Za-z0-9][A-Za-z0-9_-]*$")).match(value).hasMatch()) return {};
        path.replace(match.capturedStart(),match.capturedLength(),QString::fromLatin1(QUrl::toPercentEncoding(value)));
        match=placeholder.match(path);
    }
    return path;
}
void FeatureController::submit(const QString& actionId,const QVariantMap& values) {
    const auto* descriptor=findFeature(currentPage_); const auto* definition=findAction(actionId);
    if (!descriptor || !definition || busy_) return;
    const auto action=*definition; const auto feature=*descriptor;
    const auto id=values.value("_id",selectedId_).toString();
    if (action.selection && id.isEmpty()) { fail("Select a record first."); return; }
    const bool mutation=action.method!="GET" && action.method!="DELIVERY";
    if (!permitted(feature,mutation)) { fail("This action requires an online session with the appropriate permissions."); return; }
    if (action.destructive && values.value("_confirmed").metaType().id()!=QMetaType::Bool) { fail("Confirm this action before continuing."); return; }
    if (action.destructive && !values.value("_confirmed").toBool()) { fail("Confirm this action before continuing."); return; }
    if (action.method=="DELIVERY") { auto record=records_.record(id); if (record.isEmpty() && id==selectedId_) record=editDetails_; if (!record.isEmpty()) emit openDelivery(record); return; }
    if (action.method=="EXTERNAL") { emit requestExternal(QUrl(QStringLiteral("https://mokaid.com")+action.path)); return; }

    auto body=QJsonObject::fromVariantMap(action.defaults); QString validationError; QList<QUrl> files;
    for (const auto& fieldValue : action.fields) {
        const auto field=fieldValue.toMap();
        const auto key=field.value("key").toString();
        if (field.value("type").toString()=="files") {
            const auto value=values.value(key);
            auto list=value.toList(); if (list.isEmpty() && !value.toString().isEmpty()) list.append(value);
            for (const auto& file : list) { const auto url=file.toUrl(); if (!url.isLocalFile()) { fail("Select local files to upload."); return; } files.append(url); }
            if (files.isEmpty()) { fail("Select a file to upload."); return; }
            continue;
        }
        if (!values.contains(key) && !field.value("required").toBool()) continue;
        QJsonValue parsed;
        if (!parseField(field,values.value(key,action.defaults.value(key)),parsed,validationError)) { fail(validationError); return; }
        if (parsed.isNull() && action.method!="PATCH") continue;
        // The API deliberately omits some relationship IDs (member role/team).
        // An untouched empty control must not clear a value we were never given.
        if (parsed.isNull() && action.method=="PATCH" && !editDetails_.contains(key)) continue;
        body.insert(key,parsed);
    }
    const auto path=resolvePath(action.path,id,values);
    if (path.isEmpty()) { fail("This action needs a valid record identifier."); return; }
    if (actionId=="password" && body.value("password")!=body.value("password_confirmation")) { fail("The new passwords do not match."); return; }
    if (action.method=="UPLOAD" && (path.endsWith("/drive/upload") || path.endsWith("/avatar") || path.endsWith("/logo")) && files.size()!=1) {
        fail("Select exactly one file for this upload."); return;
    }
    const auto retryHash=QCryptographicHash::hash((currentPage_+action.id+path).toUtf8()+QJsonDocument(body).toJson(QJsonDocument::Compact),QCryptographicHash::Sha256);
    if (currentPage_=="admin-credits" && actionId=="adjust") {
        if (!retryKeys_.contains(retryHash)) retryKeys_.insert(retryHash,QUuid::createUuid().toString(QUuid::WithoutBraces));
        body.insert("idempotency_key",retryKeys_.value(retryHash));
    }
    const auto epoch=epoch_,generation=api_.context().generation;
    // A secondary report supersedes any pending primary-detail display request.
    const auto detailEpoch=action.method=="GET" ? ++detailEpoch_ : detailEpoch_;
    if (action.method=="GET") {
        detailHeading_=action.title; detailCollection_.clear();
        const auto resource=QUrl(path).path();
        if (resource=="/api/tasks") detailCollection_="tasks";
        else if (resource.startsWith("/api/drive")) detailCollection_="drive";
    }
    busy_=true; error_.clear(); emit changed();
    auto readCachedAction=[this,path,epoch,generation,detailEpoch] {
        cache_.read(cacheKey(path),this,[this,epoch,generation,detailEpoch](QByteArray bytes) {
            if (epoch!=epoch_ || generation!=api_.context().generation) return;
            busy_=false;
            if (detailEpoch!=detailEpoch_) { emit changed(); return; }
            const auto* feature=findFeature(currentPage_);
            if (!feature || feature->scope==core::Scope::administration || !permitted(*feature,false)) { clear(); emit changed(); return; }
            offline_=true;
            QJsonParseError failure; const auto document=QJsonDocument::fromJson(bytes,&failure);
            if (failure.error==QJsonParseError::NoError && document.isObject()) {
                details_=responseDetails(document.object()); error_="Offline — displaying the last synchronized data.";
            } else error_="No synchronized data is available for this action yet.";
            emit changed();
        });
    };
    if (action.method=="GET" && !api_.context().online) { readCachedAction(); return; }
    // Keep one completion path for multipart and JSON mutations.
    auto completion=[this,epoch,generation,detailEpoch,path,action,retryHash,readCachedAction](ApiResponse response) {
        if (epoch!=epoch_ || generation!=api_.context().generation) return;
        busy_=false;
        if (action.method=="GET") {
            if (detailEpoch!=detailEpoch_) { emit changed(); return; }
            const auto* feature=findFeature(currentPage_);
            if (!feature || !permitted(*feature,false)) { clear(); emit changed(); return; }
            if (response.networkError && feature->scope!=core::Scope::administration) { busy_=true; readCachedAction(); return; }
            if (!response.ok()) { fail(response.error); return; }
            if (feature->scope!=core::Scope::administration) cache_.write(cacheKey(path),response.bytes);
            offline_=false; details_=responseDetails(response.json); emit changed(); return;
        }
        if (!response.ok()) { fail(response.error); return; }
        retryKeys_.remove(retryHash);
        const auto data=response.json.value("data").toObject();
        const QUrl external(data.value("sale_url").toString(data.value("url").toString()));
        if (!external.isEmpty()) {
            if (externalUrlAllowed(external)) emit requestExternal(external);
            else { fail("The service returned an invalid external link."); return; }
        }
        if (currentPage_=="profile" || currentPage_=="settings") session_.reloadIdentity();
        if (action.method=="DELETE") clearSelection();
        refresh(); emit changed();
    };
    if (action.method=="UPLOAD") api_.upload(path,files,body,feature.scope,this,std::move(completion));
    else api_.request(action.method.toUtf8(),path,body,feature.scope,this,std::move(completion));
}
void FeatureController::fail(QString message) { error_=std::move(message); emit changed(); }
}
