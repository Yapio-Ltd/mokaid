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
            else ActivityApi::reply(socket,R"({"data":{"tasks":[{"id":"new-task","title":"Newest task"}],"projects":[],"agents":[],"knowledge":[]}})");
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
};
QTEST_GUILESS_MAIN(ActivityTests)
#include "activity_tests.moc"
