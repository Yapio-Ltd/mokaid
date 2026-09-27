#include <mokaid/application/activity_controller.hpp>
#include <QJsonArray>
#include <QJsonDocument>
#include <QPointer>
#include <QSettings>
#include <QSignalSpy>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QUrlQuery>
#include <QtTest>

using namespace mokaid::desktop;
namespace {
struct Request { QString method, path; QByteArray headers; QJsonObject body; };
class ActivityApi final : public QObject {
public:
    QTcpServer server;
    QList<Request> requests;
    std::function<void(QTcpSocket*,const Request&)> handler;
    ActivityApi() {
        server.listen(QHostAddress::LocalHost,0);
        connect(&server,&QTcpServer::newConnection,this,[this] {
            while (server.hasPendingConnections()) {
                auto* socket=server.nextPendingConnection();
                connect(socket,&QTcpSocket::disconnected,socket,&QObject::deleteLater);
                connect(socket,&QTcpSocket::readyRead,this,[this,socket] {
                    auto bytes=socket->property("request").toByteArray()+socket->readAll(); socket->setProperty("request",bytes);
                    const auto headerEnd=bytes.indexOf("\r\n\r\n");
                    if (headerEnd<0 || socket->property("handled").toBool()) return;
                    qsizetype size=0;
                    for (const auto& line : bytes.left(headerEnd).split('\n'))
                        if (line.toLower().startsWith("content-length:")) size=line.mid(15).trimmed().toLongLong();
                    const auto body=bytes.mid(headerEnd+4); if (body.size()<size) return;
                    socket->setProperty("handled",true); const auto line=bytes.left(bytes.indexOf("\r\n")).split(' ');
                    const Request request{QString::fromUtf8(line.value(0)),QString::fromUtf8(line.value(1)),bytes.left(headerEnd),QJsonDocument::fromJson(body.left(size)).object()};
                    requests.append(request);
                    if (handler) handler(socket,request); else reply(socket,R"({"data":[]})");
                });
            }
        });
    }
    QUrl origin() const { return QUrl(QString("http://127.0.0.1:%1").arg(server.serverPort())); }
    int count(const QString& path) const { int n=0; for (const auto& request : requests) if (request.path.startsWith(path)) ++n; return n; }
    static void reply(QTcpSocket* socket,const QByteArray& json,int status=200) {
        socket->write("HTTP/1.1 "+QByteArray::number(status)+" Response\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: "+QByteArray::number(json.size())+"\r\n\r\n"+json);
        socket->disconnectFromHost();
    }
};
QJsonObject completionNotice(const QString& id,const QString& task,const QString& workspace="workspace-a") {
    return {{"id",id},{"kind","ai_run_completed"},{"resource_type","task"},{"resource_id",task},
        {"workspace_id",workspace},{"title","Your result is ready"},{"read_at",QJsonValue::Null}};
}
QByteArray responseData(const QJsonValue& data) {
    return QJsonDocument(QJsonObject{{"data",data}}).toJson(QJsonDocument::Compact);
}
struct CompletionFixture {
    ActivityApi remote;
    QTemporaryDir directory;
    CacheStore cache{directory.path()};
    ApiClient api{remote.origin()};
    PhoenixClient realtime;
    SessionController session{api,realtime};
    ActivityController activity{api,session,realtime,cache};
    CompletionFixture() { api.setSession("test-alice","alice",false); api.setWorkspace("workspace-a"); emit session.changed(); }
};
}

class ActivityTests final : public QObject {
    Q_OBJECT
    QTemporaryDir preferences_;
private slots:
    void initTestCase() {
        QVERIFY(preferences_.isValid());
        QCoreApplication::setOrganizationName("MokaidActivityTests");
        QCoreApplication::setOrganizationDomain("invalid.mokaid.tests");
        QSettings::setDefaultFormat(QSettings::IniFormat);
        QSettings::setPath(QSettings::IniFormat,QSettings::UserScope,preferences_.path());
    }
    void debouncedSearchCancelsOnlyItsOwnRequest() {
        ActivityApi remote; QVERIFY(remote.server.isListening()); QPointer<QTcpSocket> oldSearch, notification;
        remote.handler=[&](QTcpSocket* socket,const Request& request) {
            if (request.path=="/api/notifications") notification=socket;
            else if (QUrlQuery(QUrl(request.path)).queryItemValue("q")=="old") oldSearch=socket;
            else ActivityApi::reply(socket,R"({"data":{"tasks":[{"id":"new-task","title":"Newest task"}],"projects":[],"agents":[],"knowledge":[{"id":"retired-page","title":"Hidden knowledge result"}]}})");
        };
        QTemporaryDir directory; CacheStore cache(directory.path()); ApiClient api(remote.origin());
        api.setSession("test-alice","alice",false); api.setWorkspace("workspace-a");
        PhoenixClient realtime; SessionController session(api,realtime); ActivityController activity(api,session,realtime,cache);
        activity.setQuery("old"); QTRY_VERIFY(oldSearch); QTRY_VERIFY(notification);
        activity.setQuery("ne"); activity.setQuery("newest");
        QTRY_VERIFY(!oldSearch || oldSearch->state()==QAbstractSocket::UnconnectedState);
        QVERIFY(notification && notification->state()==QAbstractSocket::ConnectedState);
        ActivityApi::reply(notification,R"({"data":[{"id":"notice1","title":"Real notice","read_at":null}]})");
        QTRY_COMPARE(activity.searchResults().size(),1); QTRY_COMPARE(activity.unreadCount(),1);
        QCOMPARE(activity.searchResults().first().toMap().value("id").toString(),QString("new-task"));
        QCOMPARE(activity.searchResults().first().toMap().value("page").toString(),QString("tasks"));
        QCOMPARE(remote.count("/api/search"),2);
        QSignalSpy navigation(&activity,&ActivityController::navigateRequested);
        activity.openSearchResult("admin-users","new-task"); QCOMPARE(navigation.size(),0);
        activity.openSearchResult("tasks","new-task"); QCOMPARE(navigation.size(),1); QVERIFY(activity.query().isEmpty());
        QVERIFY(activity.searchResults().isEmpty());
    }
    void notificationsUseScopedHintsAndServerConfirmedReadState() {
        ActivityApi remote; QVERIFY(remote.server.isListening()); bool read=false;
        remote.handler=[&](QTcpSocket* socket,const Request& request) {
            if (request.method=="POST") { read=true; ActivityApi::reply(socket,R"({"data":{"id":"notice1","read_at":"2026-09-14T10:00:00Z"}})"); }
            else {
                QJsonObject notice{{"id","notice1"},{"title","Task ready"},{"resource_type","task"},{"resource_id","task1"},{"read_at",read ? QJsonValue("2026-09-14T10:00:00Z") : QJsonValue(QJsonValue::Null)}};
                ActivityApi::reply(socket,QJsonDocument(QJsonObject{{"data",QJsonArray{notice}}}).toJson(QJsonDocument::Compact));
            }
        };
        QTemporaryDir directory; CacheStore cache(directory.path()); ApiClient api(remote.origin());
        api.setSession("test-alice","alice",false); api.setWorkspace("workspace-a");
        PhoenixClient realtime; SessionController session(api,realtime); ActivityController activity(api,session,realtime,cache);
        QTRY_COMPARE(activity.unreadCount(),1);
        const auto before=remote.requests.size();
        emit realtime.eventReceived("notifications:bob","notification.created",{{"title","Untrusted hint"}});
        QTest::qWait(150); QCOMPARE(remote.requests.size(),before);
        emit realtime.eventReceived("notifications:alice","notification.created",{{"title","Untrusted hint"}});
        QTRY_VERIFY(remote.requests.size()>before); QCOMPARE(activity.notifications().first().toMap().value("title").toString(),QString("Task ready"));
        QSignalSpy navigation(&activity,&ActivityController::navigateRequested); activity.openNotification("notice1");
        QTRY_COMPARE(activity.unreadCount(),0); QCOMPARE(navigation.size(),1); QCOMPARE(navigation.first().first().toString(),QString("tasks"));
        QTRY_VERIFY(!activity.busy()); QTest::qWait(150);
        const auto beforeRejoin=remote.count("/api/notifications"); emit realtime.rejoined();
        QTRY_VERIFY(remote.count("/api/notifications")>beforeRejoin);
        for (const auto& request : remote.requests) QVERIFY(request.headers.toLower().contains("x-workspace-id: workspace-a"));
    }
    void offlineCacheDoesNotCrossAccountsOrWorkspaces() {
        ActivityApi remote; QVERIFY(remote.server.isListening());
        remote.handler=[](QTcpSocket* socket,const Request& request) {
            if (request.path.startsWith("/api/search")) ActivityApi::reply(socket,R"({"data":{"tasks":[{"id":"private-task","title":"Cached private task"}]}})");
            else ActivityApi::reply(socket,R"({"data":[{"id":"private-notice","title":"Cached private notice","read_at":null}]})");
        };
        QTemporaryDir directory; CacheStore cache(directory.path()); ApiClient api(remote.origin());
        api.setSession("test-alice","alice",false); api.setWorkspace("workspace-a");
        PhoenixClient realtime; SessionController session(api,realtime); ActivityController activity(api,session,realtime,cache);
        activity.setQuery("saved"); QTRY_COMPARE(activity.searchResults().size(),1); QTRY_COMPARE(activity.notifications().size(),1);
        api.setOnline(false); activity.setQuery({}); activity.setQuery("saved");
        QTRY_VERIFY(activity.error().contains("Offline")); QTRY_COMPARE(activity.searchResults().size(),1);
        const auto count=remote.requests.size();
        activity.markRead("private-notice"); QCOMPARE(remote.requests.size(),count); QCOMPARE(activity.unreadCount(),1);
        api.setSession("test-bob","bob",true); emit session.changed();
        QCOMPARE(activity.searchResults().size(),0); QCOMPARE(activity.notifications().size(),0);
        activity.setQuery("saved"); QTest::qWait(350); QTRY_VERIFY(!activity.busy());
        QVERIFY(activity.searchResults().isEmpty()); QVERIFY(activity.notifications().isEmpty()); QCOMPARE(remote.requests.size(),count);
        api.setSession("test-alice","alice",false); api.setWorkspace("workspace-b"); emit session.workspaceChanged();
        activity.setQuery("saved"); QTest::qWait(350); QTRY_VERIFY(!activity.busy());
        QVERIFY(activity.searchResults().isEmpty()); QVERIFY(activity.notifications().isEmpty()); QCOMPARE(remote.requests.size(),count);
    }
    void workspaceCreationUsesIdentityScopeAndReloadsMembership() {
        ActivityApi remote; QVERIFY(remote.server.isListening()); bool failIdentity=true;
        remote.handler=[&](QTcpSocket* socket,const Request& request) {
            if (request.path=="/api/workspaces") ActivityApi::reply(socket,R"({"data":{"id":"new-workspace","name":"Studio"}})",201);
            else if (request.path=="/api/me" && failIdentity) ActivityApi::reply(socket,R"({"error":{"message":"Temporary failure"}})",503);
            else if (request.path=="/api/me") ActivityApi::reply(socket,R"({"user":{"id":"alice","full_name":"Alice"},"workspaces":[{"id":"new-workspace","name":"Studio"}]})");
            else ActivityApi::reply(socket,R"({"data":[]})");
        };
        QTemporaryDir directory; CacheStore cache(directory.path()); ApiClient api(remote.origin()); api.setSession("test-alice","alice",true);
        PhoenixClient realtime; SessionController session(api,realtime); ActivityController activity(api,session,realtime,cache);
        activity.setQuery("private"); QTest::qWait(300); QCOMPARE(remote.requests.size(),0); QVERIFY(activity.searchResults().isEmpty());
        activity.createWorkspace("  ","Design"); QCOMPARE(remote.requests.size(),0);
        QSignalSpy created(&activity,&ActivityController::workspaceCreated); activity.createWorkspace(" Studio "," Design ");
        QTRY_COMPARE(remote.count("/api/workspaces"),1); QTRY_VERIFY(activity.error().contains("Workspace created"));
        QCOMPARE(created.size(),0);
        QCOMPARE(remote.requests[0].body.value("name").toString(),QString("Studio"));
        QCOMPARE(remote.requests[0].body.value("industry").toString(),QString("Design"));
        QVERIFY(!remote.requests[0].headers.toLower().contains("x-workspace-id:"));
        failIdentity=false; activity.createWorkspace("Studio","Design"); QTRY_COMPARE(created.size(),1);
        QCOMPARE(remote.count("/api/workspaces"),1); QCOMPARE(session.workspaceId(),QString("new-workspace"));
        QCOMPARE(created.first().first().toString(),QString("new-workspace")); realtime.stop();
    }
    void completionsLoadCanonicalTaskAndQueueWithoutReplacingTheOpenResult() {
        CompletionFixture f;
        QJsonArray notices{completionNotice("notice-a","task-a"),completionNotice("notice-b","task-b"),
            completionNotice("foreign","foreign-task","workspace-b")};
        f.remote.handler=[&](QTcpSocket* socket,const Request& request) {
            if (request.path=="/api/notifications") { ActivityApi::reply(socket,responseData(notices)); return; }
            const auto id=request.path.section('/',-1);
            ActivityApi::reply(socket,responseData(QJsonObject{{"id",id},{"workspace_id","workspace-a"},{"title","Complete report"},
                {"assigned_agent_id","agent-a"},{"assigned_agent_name","Alice"},
                {"assigned_agent_avatar_thumbnail_url","https://assets.example.test/alice.webp"},
                {"latest_run",QJsonObject{{"id","run-a"},{"output",QJsonObject{{"response","The entire checked response."}}}}},
                {"attachments",QJsonArray{QJsonObject{{"id","file-a"},{"name","Report.pdf"},{"source","output"},{"mime_type","application/pdf"}}}}}));
        };
        f.activity.refreshNotifications(); QTRY_COMPARE(f.activity.notifications().size(),3);
        f.activity.enqueueCompletion({{"id","unverified"},{"resource_id","task-a"}});
        f.activity.enqueueCompletion(notices.at(2).toObject().toVariantMap());
        QVERIFY(f.activity.completionNotification().isEmpty());
        // The caller cannot replace the task identifier or notification text.
        f.activity.enqueueCompletion({{"id","notice-a"},{"resource_id","foreign-task"},{"title","Untrusted title"}});
        f.activity.enqueueCompletion(notices.at(1).toObject().toVariantMap());
        f.activity.enqueueCompletion(notices.at(0).toObject().toVariantMap());
        QCOMPARE(f.activity.pendingCompletionCount(),1);
        QCOMPARE(f.activity.completionNotification().value("title").toString(),QString("Your result is ready"));
        QTRY_COMPARE(f.activity.completionTask().value("id").toString(),QString("task-a"));
        QCOMPARE(f.activity.completionTask().value("assigned_agent_name").toString(),QString("Alice"));
        QCOMPARE(f.activity.completionTask().value("assigned_agent_avatar_thumbnail_url").toString(),QString("https://assets.example.test/alice.webp"));
        QCOMPARE(f.activity.completionTask().value("latest_run").toMap().value("output").toMap().value("response").toString(),QString("The entire checked response."));
        QCOMPARE(f.activity.completionTask().value("attachments").toList().first().toMap().value("id").toString(),QString("file-a"));
        QCOMPARE(f.remote.count("/api/tasks/task-a"),1); QCOMPARE(f.remote.count("/api/tasks/task-b"),0);
        QVERIFY(f.activity.completionError().isEmpty()); QVERIFY(!f.activity.completionLoading());
        f.activity.nextCompletion(); QTRY_COMPARE(f.activity.completionTask().value("id").toString(),QString("task-b"));
        QCOMPARE(f.activity.pendingCompletionCount(),0);
        f.activity.dismissCompletion(); QVERIFY(f.activity.completionTask().isEmpty());
        f.activity.enqueueCompletion(notices.at(0).toObject().toVariantMap());
        QVERIFY(f.activity.completionNotification().isEmpty()); QCOMPARE(f.remote.count("/api/tasks/task-a"),1);
        for (const auto& request : f.remote.requests) QVERIFY(request.headers.toLower().contains("x-workspace-id: workspace-a"));
    }
    void completionFailuresCanRetryAndNeverExposeMismatchedTaskData() {
        CompletionFixture f; int attempt=0;
        const auto notice=completionNotice("notice-a","task-a");
        f.remote.handler=[&](QTcpSocket* socket,const Request& request) {
            if (request.path=="/api/notifications") { ActivityApi::reply(socket,responseData(QJsonArray{notice})); return; }
            ++attempt;
            if (attempt==1) ActivityApi::reply(socket,R"({"error":{"message":"Temporary failure"}})",503);
            else if (attempt==2) ActivityApi::reply(socket,responseData(QJsonObject{{"id","task-a"},{"workspace_id","workspace-b"},{"title","Foreign result"}}));
            else ActivityApi::reply(socket,responseData(QJsonObject{{"id","task-a"},{"workspace_id","workspace-a"},{"title","Recovered result"}}));
        };
        f.activity.refreshNotifications(); QTRY_COMPARE(f.activity.notifications().size(),1);
        f.activity.enqueueCompletion(notice.toVariantMap());
        QTRY_VERIFY(!f.activity.completionLoading()); QVERIFY(!f.activity.completionError().isEmpty()); QVERIFY(f.activity.completionTask().isEmpty());
        f.activity.retryCompletion(); QTRY_VERIFY(!f.activity.completionLoading());
        QVERIFY(f.activity.completionError().contains("workspace")); QVERIFY(f.activity.completionTask().isEmpty());
        f.api.setOnline(false); f.activity.retryCompletion();
        QVERIFY(f.activity.completionError().contains("Reconnect")); QCOMPARE(attempt,2);
        f.api.setOnline(true); f.activity.retryCompletion();
        QTRY_COMPARE(f.activity.completionTask().value("title").toString(),QString("Recovered result"));
        QVERIFY(f.activity.completionError().isEmpty()); QCOMPARE(attempt,3);
    }
    void completionRequestsAndQueueAreClearedOnWorkspaceChange() {
        CompletionFixture f; QPointer<QTcpSocket> delayed;
        const QJsonArray notices{completionNotice("notice-a","task-a"),completionNotice("notice-b","task-b")};
        f.remote.handler=[&](QTcpSocket* socket,const Request& request) {
            if (request.path=="/api/notifications") ActivityApi::reply(socket,responseData(notices));
            else delayed=socket;
        };
        f.activity.refreshNotifications(); QTRY_COMPARE(f.activity.notifications().size(),2);
        f.activity.enqueueCompletion(notices.at(0).toObject().toVariantMap());
        f.activity.enqueueCompletion(notices.at(1).toObject().toVariantMap());
        QTRY_VERIFY(delayed); QVERIFY(f.activity.completionLoading()); QCOMPARE(f.activity.pendingCompletionCount(),1);
        f.api.setWorkspace("workspace-b"); emit f.session.workspaceChanged();
        QVERIFY(f.activity.completionNotification().isEmpty()); QVERIFY(f.activity.completionTask().isEmpty());
        QVERIFY(f.activity.completionError().isEmpty()); QVERIFY(!f.activity.completionLoading()); QCOMPARE(f.activity.pendingCompletionCount(),0);
        QTRY_VERIFY(!delayed || delayed->state()==QAbstractSocket::UnconnectedState);
        // A scoped endpoint in the new workspace must not revive old notices.
        f.activity.refreshNotifications(); QTRY_COMPARE(f.activity.notifications().size(),2);
        f.activity.enqueueCompletion(notices.at(0).toObject().toVariantMap());
        QVERIFY(f.activity.completionNotification().isEmpty()); QCOMPARE(f.remote.count("/api/tasks/task-b"),0);
    }
};
QTEST_GUILESS_MAIN(ActivityTests)
#include "activity_tests.moc"
