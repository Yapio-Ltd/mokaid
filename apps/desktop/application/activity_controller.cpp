#include <mokaid/application/activity_controller.hpp>
#include <QJsonArray>
#include <QJsonDocument>
#include <QRegularExpression>
#include <QUrlQuery>

namespace mokaid::desktop {
namespace {
bool identifier(const QString& value) {
    static const QRegularExpression pattern(QStringLiteral("^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$"));
    return pattern.match(value).hasMatch();
}
QString pageForResource(const QString& resource) {
    if (resource=="task") return "tasks";
    if (resource=="project") return "projects";
    if (resource=="agent") return "agents";
    return {};
}
}
ActivityController::ActivityController(ApiClient& api, SessionController& session, PhoenixClient& realtime,
                                       CacheStore& cache, QObject* parent)
    : QObject(parent),api_(api),session_(session),realtime_(realtime),cache_(cache) {
    searchTimer_.setSingleShot(true); searchTimer_.setInterval(250);
    notificationTimer_.setSingleShot(true); notificationTimer_.setInterval(100);
    connect(&searchTimer_,&QTimer::timeout,this,&ActivityController::runSearch);
    connect(&notificationTimer_,&QTimer::timeout,this,&ActivityController::refreshNotifications);
    connect(&session_,&SessionController::changed,this,&ActivityController::contextChanged);
    connect(&session_,&SessionController::workspaceChanged,this,&ActivityController::contextChanged);
    connect(&session_,&SessionController::cleared,this,[this] { clear(); context_.clear(); emit changed(); });
    connect(&session_,&SessionController::established,this,[this] {
        contextChanged();
        if (!pendingWorkspace_.isEmpty()) {
            const auto requested=pendingWorkspace_;
            bool found=false;
            for (const auto& workspace : session_.workspaces()) if (workspace.toMap().value("id")==requested) found=true;
            if (found) {
                pendingWorkspace_.clear(); pendingUser_.clear(); creating_=false; session_.selectWorkspace(requested);
                emit workspaceCreated(requested); emit changed();
            } else { creating_=false; fail("Workspace created, but its membership is not available yet. Refresh your session before creating another."); }
        }
        refreshNotifications();
    });
    connect(&api_,&ApiClient::onlineChanged,this,[this](bool online) {
        contextChanged();
        if (!online) {
            api_.cancelRequests(&searchOwner_); ++searchEpoch_; searchBusy_=false;
            if (query_.trimmed().size()>=2) searchTimer_.start();
        }
        if (canReadCache()) notificationTimer_.start();
    });
    connect(&realtime_,&PhoenixClient::rejoined,this,[this] {
        if (canReadCache()) notificationTimer_.start();
        if (query_.trimmed().size()>=2) searchTimer_.start();
    });
    connect(&realtime_,&PhoenixClient::eventReceived,this,[this](const QString& topic,const QString& event,const QJsonObject&) {
        // Notification broadcasts intentionally contain no workspace. Treat them
        // only as invalidation hints and reload this customer's scoped endpoint.
        if (topic=="notifications:"+userId() && event=="notification.created" && canReadCache()) notificationTimer_.start();
    });
    contextChanged();
}
QString ActivityController::userId() const {
    return api_.context().authenticated ? QString::fromStdString(api_.context().user_id)
        : session_.authenticated() ? session_.user().value("id").toString() : QString{};
}
QString ActivityController::workspaceId() const {
    return api_.context().authenticated ? QString::fromStdString(api_.context().workspace_id)
        : session_.authenticated() ? session_.workspaceId() : QString{};
}
QString ActivityController::contextKey() const {
    return QString::fromStdString(core::cacheKey(api_.origin().toString().toStdString(),userId().toStdString(),workspaceId().toStdString(),"activity"));
}
QString ActivityController::cacheKey(const QString& path) const {
    return QString::fromStdString(core::cacheKey(api_.origin().toString().toStdString(),userId().toStdString(),workspaceId().toStdString(),path.toStdString()));
}
bool ActivityController::canReadCache() const { return !userId().isEmpty() && !workspaceId().isEmpty(); }
bool ActivityController::current(quint64 generation,const QString& context) const {
    return generation==api_.context().generation && context==contextKey();
}
void ActivityController::clear() {
    ++searchEpoch_; ++notificationEpoch_;
    api_.cancelRequests(&searchOwner_); api_.cancelRequests(&notificationOwner_); api_.cancelRequests(&mutationOwner_);
    searchTimer_.stop(); notificationTimer_.stop(); searchResults_.clear(); notifications_.clear();
    marking_.clear(); readAt_.clear(); query_.clear(); error_.clear(); pendingWorkspace_.clear(); pendingUser_.clear();
    searchBusy_=false; notificationsBusy_=false; creating_=false; refreshPending_=false;
}
void ActivityController::contextChanged() {
    const auto key=contextKey(); const auto generation=api_.context().generation;
    if (key!=context_ || generation!=generation_) {
        // Membership refresh after successful creation may switch workspaces.
        // Keep that pending selection only while the same user stays signed in.
        const auto pending=pendingWorkspace_, pendingUser=pendingUser_;
        const bool preserveCreation=!pending.isEmpty() && api_.context().authenticated && pendingUser==userId();
        clear(); context_=key; generation_=generation;
        if (preserveCreation) { pendingWorkspace_=pending; pendingUser_=pendingUser; creating_=true; }
        if (canReadCache()) notificationTimer_.start();
    }
    if (creating_ && !pendingWorkspace_.isEmpty() && !session_.busy() && !session_.error().isEmpty()) {
        creating_=false; error_="Workspace created, but your session could not refresh. Retry to reload the existing workspace.";
    }
    emit changed();
}
int ActivityController::unreadCount() const {
    int count=0;
    for (const auto& value : notifications_) if (value.toMap().value("read_at").toString().isEmpty()) ++count;
    return count;
}
void ActivityController::setQuery(const QString& text) {
    const auto next=text.left(256); if (query_==next) return;
    query_=next; ++searchEpoch_; searchTimer_.stop(); api_.cancelRequests(&searchOwner_);
    searchBusy_=false; searchResults_.clear(); error_.clear();
    if (query_.trimmed().size()>=2) searchTimer_.start();
    emit changed();
}
void ActivityController::runSearch() {
    if (query_.trimmed().size()<2) return;
    if (!canReadCache()) { searchBusy_=false; fail("Select a workspace to search."); return; }
    QUrl url("/api/search"); QUrlQuery query; query.addQueryItem("q",query_.trimmed()); url.setQuery(query);
    const auto path=url.toString(QUrl::FullyEncoded), context=contextKey();
    const auto epoch=++searchEpoch_, generation=api_.context().generation;
    api_.cancelRequests(&searchOwner_); searchBusy_=true; error_.clear(); emit changed();
    if (!api_.context().online || !core::mayRequest(api_.context(),core::Scope::workspace,false)) { readSearchCache(path,epoch,generation,context); return; }
    api_.request("GET",path,{},core::Scope::workspace,&searchOwner_,[this,path,epoch,generation,context](ApiResponse response) {
        if (epoch!=searchEpoch_ || !current(generation,context)) return;
        if (response.networkError) { readSearchCache(path,epoch,generation,context); return; }
        searchBusy_=false;
        if (!response.ok()) { fail(response.error); return; }
        if (!response.json.value("data").isObject()) { fail("The search response is invalid."); return; }
        cache_.write(cacheKey(path),response.bytes); acceptSearch(response.json); emit changed();
    });
}
void ActivityController::acceptSearch(const QJsonObject& response) {
    searchResults_.clear(); const auto data=response.value("data").toObject();
    for (const auto& page : {QString("tasks"),QString("projects"),QString("agents")}) {
        int count=0;
        for (const auto& value : data.value(page).toArray()) {
            if (!value.isObject() || ++count>5) break;
            auto record=value.toObject().toVariantMap();
            if (!identifier(record.value("id").toString())) continue;
            record.insert("page",page); record.insert("section",page.left(1).toUpper()+page.mid(1)); searchResults_.append(record);
        }
    }
}
void ActivityController::readSearchCache(const QString& path,quint64 epoch,quint64 generation,const QString& context) {
    cache_.read(cacheKey(path),&searchOwner_,[this,epoch,generation,context](QByteArray bytes) {
        if (epoch!=searchEpoch_ || !current(generation,context)) return;
        searchBusy_=false; const auto document=QJsonDocument::fromJson(bytes);
        if (document.isObject() && document.object().value("data").isObject()) {
            acceptSearch(document.object()); error_="Offline — displaying the last synchronized results for this search.";
        } else { searchResults_.clear(); error_="No synchronized results are available for this search."; }
        emit changed();
    });
}
void ActivityController::refreshNotifications() {
    if (!canReadCache()) return;
    if (notificationsBusy_) { refreshPending_=true; return; }
    const auto epoch=++notificationEpoch_, generation=api_.context().generation;
    const auto context=contextKey(); notificationsBusy_=true; refreshPending_=false; emit changed();
    if (!api_.context().online || !core::mayRequest(api_.context(),core::Scope::workspace,false)) { readNotificationsCache(epoch,generation,context); return; }
    api_.request("GET","/api/notifications",{},core::Scope::workspace,&notificationOwner_,[this,epoch,generation,context](ApiResponse response) {
        if (epoch!=notificationEpoch_ || !current(generation,context)) return;
        if (response.networkError) { readNotificationsCache(epoch,generation,context); return; }
        notificationsBusy_=false;
        if (!response.ok()) { fail(response.error); }
        else if (!response.json.value("data").isArray()) fail("The notification response is invalid.");
        else {
            cache_.write(cacheKey("/api/notifications"),response.bytes); acceptNotifications(response.json);
            if (error_.startsWith("Offline — displaying the last synchronized notifications") || error_=="No synchronized notifications are available yet.") error_.clear();
            emit changed();
        }
        if (refreshPending_) notificationTimer_.start();
    });
}
void ActivityController::acceptNotifications(const QJsonObject& response) {
    notifications_.clear(); QSet<QString> seen;
    for (const auto& value : response.value("data").toArray()) {
        if (!value.isObject() || notifications_.size()>=50) break;
        auto record=value.toObject().toVariantMap(); const auto id=record.value("id").toString();
        if (!identifier(id) || seen.contains(id)) continue;
        seen.insert(id);
        if (readAt_.contains(id)) record.insert("read_at",readAt_.value(id));
        notifications_.append(record);
    }
    for (auto it=readAt_.begin();it!=readAt_.end();) {
        if (!seen.contains(it.key())) it=readAt_.erase(it); else ++it;
    }
}
void ActivityController::readNotificationsCache(quint64 epoch,quint64 generation,const QString& context) {
    cache_.read(cacheKey("/api/notifications"),&notificationOwner_,[this,epoch,generation,context](QByteArray bytes) {
        if (epoch!=notificationEpoch_ || !current(generation,context)) return;
        notificationsBusy_=false; const auto document=QJsonDocument::fromJson(bytes);
        if (document.isObject() && document.object().value("data").isArray()) {
            acceptNotifications(document.object()); error_="Offline — displaying the last synchronized notifications.";
        } else { notifications_.clear(); error_="No synchronized notifications are available yet."; }
        emit changed();
        if (refreshPending_) notificationTimer_.start();
    });
}
void ActivityController::markRead(const QString& id) {
    if (marking_.contains(id)) return;
    if (!api_.context().online || !core::mayRequest(api_.context(),core::Scope::workspace,true)) { fail("An online workspace session is required to mark notifications read."); return; }
    bool found=false;
    for (const auto& value : notifications_) if (value.toMap().value("id")==id) { found=true; if (!value.toMap().value("read_at").toString().isEmpty()) return; }
    if (!found || !identifier(id)) { fail("Select a notification from the current workspace."); return; }
    const auto generation=api_.context().generation; const auto context=contextKey();
    marking_.insert(id); error_.clear(); emit changed();
    api_.request("POST","/api/notifications/"+id+"/read",{},core::Scope::workspace,&mutationOwner_,[this,id,generation,context](ApiResponse response) {
        if (!current(generation,context)) return;
        marking_.remove(id);
        if (!response.ok()) { fail(response.error); return; }
        const auto data=response.json.value("data").toObject(); const auto read=data.value("read_at").toString();
        if (data.value("id").toString()!=id || read.isEmpty()) { fail("The notification update response is invalid."); return; }
        readAt_.insert(id,read);
        for (auto& value : notifications_) { auto record=value.toMap(); if (record.value("id")==id) { record.insert("read_at",read); value=record; } }
        emit changed(); notificationTimer_.start();
    });
}
void ActivityController::createWorkspace(const QString& name,const QString& industry) {
    if (creating_) return;
    if (!api_.context().online || !core::mayRequest(api_.context(),core::Scope::identity,true)) { fail("Sign in online before creating a workspace."); return; }
    if (!pendingWorkspace_.isEmpty()) { creating_=true; error_.clear(); session_.reloadIdentity(); emit changed(); return; }
    const auto title=name.trimmed(), sector=industry.trimmed();
    if (title.isEmpty() || title.size()>100 || sector.size()>100 || title.contains(QChar::Null) || title.contains('\n') || title.contains('\r')) {
        fail("Enter a workspace name between 1 and 100 characters and an industry of at most 100 characters."); return;
    }
    QJsonObject body{{"name",title}}; if (!sector.isEmpty()) body.insert("industry",sector);
    const auto generation=api_.context().generation; const auto context=contextKey();
    creating_=true; error_.clear(); emit changed();
    api_.request("POST","/api/workspaces",body,core::Scope::identity,&mutationOwner_,[this,generation,context](ApiResponse response) {
        if (!current(generation,context)) return;
        if (!response.ok()) { creating_=false; fail(response.error); return; }
        const auto id=response.json.value("data").toObject().value("id").toString();
        if (!identifier(id)) { creating_=false; fail("The workspace creation response is invalid. Refresh your session before retrying."); return; }
        pendingWorkspace_=id; pendingUser_=userId(); session_.reloadIdentity(); emit changed();
    });
}
void ActivityController::openSearchResult(const QString& page,const QString& id) {
    for (const auto& value : searchResults_) {
        const auto record=value.toMap();
        if (record.value("page")==page && record.value("id")==id) { emit navigateRequested(page,id); setQuery({}); return; }
    }
}
void ActivityController::openNotification(const QString& id) {
    for (const auto& value : notifications_) {
        const auto record=value.toMap(); if (record.value("id")!=id) continue;
        const auto page=pageForResource(record.value("resource_type").toString()), resource=record.value("resource_id").toString();
        if (!page.isEmpty() && identifier(resource)) emit navigateRequested(page,resource);
        if (api_.context().online) markRead(id);
        return;
    }
}
void ActivityController::fail(QString error) { error_=std::move(error); emit changed(); }
}
