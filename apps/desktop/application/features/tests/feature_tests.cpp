#include <mokaid/features/feature_catalog.hpp>
#include <mokaid/features/feature_controller.hpp>
#include <mokaid/features/record_list_model.hpp>
#include <QAbstractItemModelTester>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonArray>
#include <QSet>
#include <QSignalSpy>
#include <QSqlDatabase>
#include <QSqlQuery>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QtTest>

using namespace mokaid::desktop;

QString detailRow(DetailBrowser& browser,const QString& key) {
    const auto* model=browser.rows();
    for (int row=0;row<model->rowCount();++row) {
        const auto index=model->index(row,0); const auto record=model->data(index,RecordListModel::Record).toMap();
        if (record.value("nodeKey")==key) return model->data(index,RecordListModel::RowId).toString();
    }
    return {};
}
// Real HTTP transport against an isolated loopback fixture; never contacts Mokaid.
class LocalApi final : public QObject {
public:
    QTcpServer server;
    QStringList paths;
    QStringList methods;
    QList<QJsonObject> bodies;
    std::function<void(QTcpSocket*,const QString&)> handler;
    LocalApi() {
        server.listen(QHostAddress::LocalHost,0);
        connect(&server,&QTcpServer::newConnection,this,[this] {
            while (server.hasPendingConnections()) {
                auto* socket=server.nextPendingConnection();
                connect(socket,&QTcpSocket::disconnected,socket,&QObject::deleteLater);
                connect(socket,&QTcpSocket::readyRead,this,[this,socket] {
                    auto bytes=socket->property("request").toByteArray()+socket->readAll();
                    socket->setProperty("request",bytes);
                    if (!bytes.contains("\r\n\r\n") || socket->property("handled").toBool()) return;
                    const auto headersEnd=bytes.indexOf("\r\n\r\n");
                    qsizetype length=0;
                    for (const auto& line : bytes.left(headersEnd).split('\n'))
                        if (line.toLower().startsWith("content-length:")) length=line.mid(15).trimmed().toLongLong();
                    const auto body=bytes.mid(headersEnd+4);
                    if (body.size()<length) return;
                    socket->setProperty("handled",true);
                    const auto path=QString::fromUtf8(bytes.split(' ').value(1)); paths.append(path);
                    methods.append(QString::fromUtf8(bytes.split(' ').value(0)));
                    bodies.append(QJsonDocument::fromJson(body.left(length)).object());
                    if (handler) handler(socket,path);
                });
            }
        });
    }
    QUrl origin() const { return QUrl(QString("http://127.0.0.1:%1").arg(server.serverPort())); }
    static void reply(QTcpSocket* socket,const QByteArray& json,int status=200,const QByteArray& mime="application/json") {
        socket->write("HTTP/1.1 "+QByteArray::number(status)+" Response\r\nContent-Type: "+mime+"\r\nConnection: close\r\nContent-Length: "+QByteArray::number(json.size())+"\r\n\r\n"+json);
        socket->disconnectFromHost();
    }
};

struct DriveFixture {
    LocalApi remote;
    QTemporaryDir directory;
    CacheStore cache{directory.path()};
    ApiClient api{remote.origin()};
    PhoenixClient realtime;
    SessionController session{api,realtime};
    QMap<QString,QJsonObject> items;
    std::unique_ptr<FeatureController> controller;
    std::function<bool(QTcpSocket*,const QString&)> intercept;
    DriveFixture() {
        for (const auto& item : QJsonArray{
            QJsonObject{{"id","folder-a"},{"name","Folder A"},{"kind","folder"},{"status","active"}},
            QJsonObject{{"id","folder-b"},{"name","Folder B"},{"kind","folder"},{"status","active"},{"parent_id","folder-a"}},
            QJsonObject{{"id","file-a"},{"name","report.json"},{"kind","file"},{"status","active"},{"parent_id","folder-a"},{"size_bytes",12}},
            QJsonObject{{"id","trash-a"},{"name","Removed file"},{"kind","file"},{"status","trashed"},{"parent_id","folder-a"}}})
            items.insert(item.toObject().value("id").toString(),item.toObject());
        remote.handler=[this](QTcpSocket* socket,const QString& path) {
            if (intercept && intercept(socket,path)) return;
            const auto method=remote.methods.last();
            const auto id=path.section('/',3,3);
            if (method=="POST" && path.endsWith("/restore")) {
                items[id].insert("status","active"); LocalApi::reply(socket,QJsonDocument(QJsonObject{{"data",items[id]}}).toJson());
            } else if (method=="DELETE") {
                items[id].insert("status","trashed"); LocalApi::reply(socket,"{}",204);
            } else if (method=="POST" && path=="/api/drive") {
                auto record=remote.bodies.last(); record.insert("id","created"); record.insert("status","active"); items.insert("created",record);
                LocalApi::reply(socket,QJsonDocument(QJsonObject{{"data",record}}).toJson(),201);
            } else if (path=="/api/drive" || path=="/api/drive-trash" || path.endsWith("/children")) {
                QJsonArray rows;
                const bool trash=path=="/api/drive-trash";
                const auto parent=path.endsWith("/children")?id:QString{};
                for (const auto& item : items) if (item.value("status")== (trash?"trashed":"active")
                    && (trash || item.value("parent_id").toString()==parent)) rows.append(item);
                LocalApi::reply(socket,QJsonDocument(QJsonObject{{"data",rows}}).toJson());
            } else LocalApi::reply(socket,QJsonDocument(QJsonObject{{"data",items.value(id)}}).toJson());
        };
        api.setSession("test-alice","alice",false); api.setWorkspace("workspace-a");
        controller=std::make_unique<FeatureController>(api,session,cache);
    }
    DriveDownload& download() { return *qobject_cast<DriveDownload*>(controller->driveDownload()); }
    static QByteArray contents(const QString& path) { QFile file(path); return file.open(QIODevice::ReadOnly)?file.readAll():QByteArray{}; }
};

struct TaskFixture {
    LocalApi remote;
    QTemporaryDir directory;
    CacheStore cache{directory.path()};
    ApiClient api{remote.origin()};
    PhoenixClient realtime;
    SessionController session{api,realtime};
    QMap<QString,QJsonObject> items{
        {"task-a",{{"id","task-a"},{"title","Keep the SEO brief"},{"description","A detailed original brief"},
            {"status","to_do"},{"assigned_agent_id","agent-a"},{"project_id","project-a"},{"priority","high"}}},
        {"task-b",{{"id","task-b"},{"title","Another task"},{"status","blocked"},{"assigned_agent_id","agent-b"}}}};
    bool canUpdate{true};
    std::function<bool(QTcpSocket*,const QString&)> intercept;
    std::unique_ptr<FeatureController> controller;
    TaskFixture() {
        remote.handler=[this](QTcpSocket* socket,const QString& path) {
            if (intercept && intercept(socket,path)) return;
            const auto id=path.section('/',3,3);
            if (path=="/api/tasks") {
                QJsonArray rows; for (const auto& item : items) rows.append(item);
                LocalApi::reply(socket,QJsonDocument(QJsonObject{{"data",rows},{"meta",QJsonObject{
                    {"current_member_id","member-alice"},{"can_update",canUpdate},
                    {"counts",QJsonObject{{"to_do",1},{"blocked",1},{"in_progress",0}}}}}}).toJson());
            } else if (path.endsWith("/runs")) {
                LocalApi::reply(socket,R"({"data":[{"id":"run-a","status":"completed","result":"SEO report retained"}]})");
            } else if (remote.methods.last()=="PATCH") {
                const auto body=remote.bodies.last();
                for (auto it=body.begin();it!=body.end();++it) items[id].insert(it.key(),it.value());
                LocalApi::reply(socket,QJsonDocument(QJsonObject{{"data",items[id]}}).toJson());
            } else if (items.contains(id)) {
                auto item=items[id]; item.insert("comments",QJsonArray{QJsonObject{{"id","comment-a"},{"body","Retain this discussion"}}});
                LocalApi::reply(socket,QJsonDocument(QJsonObject{{"data",item}}).toJson());
            } else LocalApi::reply(socket,R"({"data":[]})");
        };
        api.setSession("test-alice","alice",false); api.setWorkspace("workspace-a");
        controller=std::make_unique<FeatureController>(api,session,cache);
        controller->navigate("tasks");
    }
    QVariantMap task(const QString& id) const {
        for (const auto& item : controller->allRecords()) if (item.toMap().value("id")==id) return item.toMap();
        return {};
    }
};

class FeatureTests final : public QObject {
    Q_OBJECT
private slots:
    void mailOAuthCancellationWaitsForTheServerAndHonorsCompletionRace() {
        LocalApi remote; QVERIFY(remote.server.isListening());
        ApiClient api(remote.origin()); PhoenixClient realtime; SessionController session(api,realtime);
        api.setSession("test-mail-session","user-a",false); api.setWorkspace("workspace-a");
        MailAccountsController mail(api,session);
        int cancellationAttempts=0; QString cancelStatus="failed";
        remote.handler=[&](QTcpSocket* socket,const QString& path) {
            if (path.endsWith("/google/start")) LocalApi::reply(socket,"{\"data\":{\"flow_id\":\"fixture-flow\",\"authorize_url\":\"https://accounts.google.com/o/oauth2/v2/auth?state=test-only\"}}");
            else if (remote.methods.last()=="DELETE") {
                if (++cancellationAttempts==1) LocalApi::reply(socket,"{\"error\":{\"message\":\"Temporary failure\"}}",503);
                else LocalApi::reply(socket,QJsonDocument(QJsonObject{{"data",QJsonObject{{"status",cancelStatus},{"error","authorization_cancelled"}}}}).toJson());
            } else LocalApi::reply(socket,"{\"data\":[]}");
        };
        QSignalSpy connected(&mail,&MailAccountsController::connected);
        mail.connectGoogle(); QTRY_VERIFY(mail.oauthPending()); mail.cancelOAuth();
        QTRY_VERIFY(!mail.submitting()); QVERIFY(mail.oauthPending()); QVERIFY(mail.error().contains("could not be cancelled"));
        mail.cancelOAuth(); QTRY_VERIFY(!mail.oauthPending()); QCOMPARE(connected.count(),0); QVERIFY(mail.error().isEmpty());
        mail.connectGoogle(); QTRY_VERIFY(mail.oauthPending()); cancelStatus="connected"; mail.cancelOAuth();
        QTRY_COMPARE(connected.count(),1); QVERIFY(!mail.oauthPending());
    }
    void mailImapUsesValidatedTransportAndKeepsCredentialsOutOfAccounts() {
        LocalApi remote; QVERIFY(remote.server.isListening());
        ApiClient api(remote.origin()); PhoenixClient realtime; SessionController session(api,realtime);
        api.setSession("test-mail-session","user-a",false); api.setWorkspace("workspace-a");
        MailAccountsController mail(api,session);
        const QJsonArray accounts{QJsonObject{{"id","mail-a"},{"email_address","alice@example.test"},{"provider","imap"},{"password","must-not-display"},
            {"settings",QJsonObject{{"imap_host","imap.example.test"},{"password","must-not-display"},{"access_token","must-not-display"}}}}};
        remote.handler=[&](QTcpSocket* socket,const QString& path) {
            if (path=="/api/mail/accounts") LocalApi::reply(socket,QJsonDocument(QJsonObject{{"data",accounts}}).toJson());
            else LocalApi::reply(socket,"{\"data\":{\"id\":\"mail-a\"}}",201);
        };
        mail.refresh(); QTRY_COMPARE(mail.accounts().size(),1);
        const auto account=mail.accounts().first().toMap();
        QVERIFY(!account.contains("password")); QVERIFY(!account.value("settings").toMap().contains("password"));
        QVERIFY(!account.value("settings").toMap().contains("access_token"));
        QCOMPARE(account.value("settings").toMap().value("imap_host").toString(),QString("imap.example.test"));
        QVariantMap draft{{"email_address"," alice@example.test "},{"password","test-only-password"},{"username","  "},
            {"imap_host","imap.example.test"},{"imap_port","993"},{"imap_security","tls"},
            {"smtp_enabled",true},{"smtp_host","smtp.example.test"},{"smtp_port","587"},{"smtp_security","starttls"}};
        QSignalSpy connected(&mail,&MailAccountsController::connected);
        mail.connectImap(draft); QTRY_COMPARE(connected.count(),1);
        const auto index=remote.paths.indexOf("/api/mail/accounts/imap"); QVERIFY(index>=0);
        QCOMPARE(remote.methods.at(index),QString("POST"));
        const auto body=remote.bodies.at(index);
        QCOMPARE(body.value("username").toString(),QString("alice@example.test"));
        QCOMPARE(body.value("email_address").toString(),QString("alice@example.test"));
        QCOMPARE(body.value("smtp_security").toString(),QString("starttls"));
        QCOMPARE(body.value("smtp_port").toInt(),587); QVERIFY(!body.contains("smtp_ssl"));
        mail.connectImap(draft,"mail-a"); QTRY_COMPARE(connected.count(),2);
        QCOMPARE(remote.methods.at(remote.paths.indexOf("/api/mail/accounts/mail-a/imap")),QString("PUT"));
        const int before=remote.paths.size(); draft.insert("smtp_host",""); mail.connectImap(draft);
        QVERIFY(mail.error().contains("SMTP")); QVERIFY(!mail.submitting()); QCOMPARE(remote.paths.size(),before);
        draft.insert("smtp_enabled",false); draft.insert("imap_security","none"); mail.connectImap(draft);
        QVERIFY(mail.error().contains("TLS")); QVERIFY(!mail.submitting());
        draft.insert("imap_security","tls"); draft.insert("imap_port","70000"); mail.connectImap(draft);
        QVERIFY(mail.error().contains("port")); QVERIFY(!mail.submitting());
    }
    void mailOAuthWaitsForServerCompletionAndResetsAcrossWorkspaces() {
        LocalApi remote; QVERIFY(remote.server.isListening());
        ApiClient api(remote.origin()); PhoenixClient realtime; SessionController session(api,realtime);
        api.setSession("test-mail-session","user-a",false); api.setWorkspace("workspace-a");
        MailAccountsController mail(api,session);
        QString status="pending";
        remote.handler=[&](QTcpSocket* socket,const QString& path) {
            QJsonObject data;
            if (path.endsWith("/google/start")) data={{"flow_id","fixture-flow"},{"authorize_url","https://accounts.google.com/o/oauth2/v2/auth?state=test-only"}};
            else if (path.endsWith("/fixture-flow")) data={{"status",status}};
            else { LocalApi::reply(socket,"{\"data\":[]}"); return; }
            LocalApi::reply(socket,QJsonDocument(QJsonObject{{"data",data}}).toJson());
        };
        QSignalSpy browser(&mail,&MailAccountsController::requestExternal), connected(&mail,&MailAccountsController::connected), reset(&mail,&MailAccountsController::contextReset);
        mail.connectGoogle(); QTRY_COMPARE(browser.count(),1); QVERIFY(mail.oauthPending()); QCOMPARE(connected.count(),0);
        mail.checkOAuth(); QTRY_VERIFY(remote.paths.contains("/api/mail/oauth/fixture-flow")); QTest::qWait(20);
        QVERIFY(mail.oauthPending()); QCOMPARE(connected.count(),0);
        status="connected"; mail.checkOAuth(); QTRY_COMPARE(connected.count(),1); QVERIFY(!mail.oauthPending());
        status="pending"; mail.connectGoogle(); QTRY_COMPARE(browser.count(),2); QVERIFY(mail.oauthPending());
        api.setWorkspace("workspace-b"); mail.setActive(true);
        QTRY_VERIFY(!mail.oauthPending()); QCOMPARE(reset.count(),1); QCOMPARE(mail.accounts().size(),0); QCOMPARE(mail.selectedId(),QString());
        QVERIFY(!mail.submitting());
    }
    void mailRejectsUntrustedOAuthLinksAndShowsServerValidationErrors() {
        LocalApi remote; QVERIFY(remote.server.isListening());
        ApiClient api(remote.origin()); PhoenixClient realtime; SessionController session(api,realtime);
        api.setSession("test-mail-session","user-a",false); api.setWorkspace("workspace-a");
        MailAccountsController mail(api,session);
        QString authorizeUrl="https://accounts.google.com.evil.test/login";
        remote.handler=[&](QTcpSocket* socket,const QString& path) {
            if (path.endsWith("/google/start")) LocalApi::reply(socket,QJsonDocument(QJsonObject{{"data",QJsonObject{{"flow_id","test-flow"},{"authorize_url",authorizeUrl}}}}).toJson());
            else LocalApi::reply(socket,"{\"error\":{\"code\":\"smtp_connection_failed\",\"message\":\"SMTP authentication failed. Create an app password.\"}}",422);
        };
        QSignalSpy browser(&mail,&MailAccountsController::requestExternal);
        for (const auto* candidate : {"https://accounts.google.com.evil.test/login", "https://accounts.google.com:8443/o/oauth2/v2/auth", "https://accounts.google.com/unexpected/path", "https://accounts.google.com/o/oauth2/v2/auth#fragment"}) {
            authorizeUrl=candidate; mail.connectGoogle(); QTRY_VERIFY(!mail.submitting()); QVERIFY(!mail.oauthPending()); QCOMPARE(browser.count(),0); QVERIFY(!mail.error().isEmpty());
        }
        mail.connectImap({{"email_address","alice@example.test"},{"password","fixture-password"},{"imap_host","imap.example.test"},{"imap_port",993},{"imap_security","tls"}});
        QTRY_VERIFY(!mail.submitting()); QCOMPARE(mail.error(),QString("SMTP authentication failed. Create an app password."));
        QVERIFY(mail.accounts().isEmpty());
    }
    void mailAccountSelectionUsesServerFilterAndSyncUsesActualIds() {
        LocalApi remote; QVERIFY(remote.server.isListening()); QTemporaryDir directory;
        ApiClient api(remote.origin()); PhoenixClient realtime; SessionController session(api,realtime); CacheStore cache(directory.path());
        api.setSession("test-mail-session","user-a",false); api.setWorkspace("workspace-a");
        remote.handler=[](QTcpSocket* socket,const QString& path) {
            if (path=="/api/mail/accounts") LocalApi::reply(socket,"{\"data\":[{\"id\":\"mail-a\",\"email_address\":\"a@example.test\"},{\"id\":\"mail-b\",\"email_address\":\"b@example.test\"}]}");
            else LocalApi::reply(socket,"{\"data\":[]}");
        };
        FeatureController features(api,session,cache); features.navigate("mail");
        auto& mail=*qobject_cast<MailAccountsController*>(features.mailAccounts());
        QTRY_COMPARE(mail.accounts().size(),2); QTRY_VERIFY(!features.busy());
        mail.select("mail-b"); QTRY_VERIFY(remote.paths.contains("/api/mail/messages?account_id=mail-b")); QTRY_VERIFY(!features.busy());
        mail.synchronize(); QTRY_VERIFY(remote.paths.contains("/api/mail/accounts/mail-b/sync")); QTRY_VERIFY(!mail.syncing());
        QVERIFY(!remote.paths.contains("/api/mail/accounts/mail-a/sync"));
        mail.select(""); mail.synchronize(); QTRY_VERIFY(remote.paths.contains("/api/mail/accounts/mail-a/sync"));
    }
    void taskMovePatchesOnlyStatusWithoutChangingUnrelatedSelection() {
        TaskFixture f; auto& c=*f.controller;
        QTRY_COMPARE(c.allRecords().size(),2); QVERIFY(c.canMoveTasks());
        QCOMPARE(c.currentMemberId(),QString("member-alice"));
        c.select("task-b"); QTRY_VERIFY(c.selectedRecord().contains("comments"));
        const auto selected=c.selectedRecord(); const auto requests=f.remote.paths.size();
        QSignalSpy result(&c,&FeatureController::actionResult);
        QVERIFY(c.moveTask("task-a","in_progress"));
        QCOMPARE(c.pendingTaskId(),QString("task-a")); QCOMPARE(c.pendingTaskStatus(),QString("in_progress"));
        QVERIFY(c.busy()); QVERIFY(!c.canMoveTasks());
        QCOMPARE(f.task("task-a").value("status").toString(),QString("to_do"));
        QTRY_VERIFY(!c.busy());
        QCOMPARE(f.remote.paths.size(),requests+1);
        QCOMPARE(f.remote.methods.last(),QString("PATCH")); QCOMPARE(f.remote.paths.last(),QString("/api/tasks/task-a"));
        QCOMPARE(f.remote.bodies.last(),QJsonObject({{"status","in_progress"}}));
        QCOMPARE(f.task("task-a").value("title").toString(),QString("Keep the SEO brief"));
        QCOMPARE(f.task("task-a").value("description").toString(),QString("A detailed original brief"));
        QCOMPARE(f.task("task-a").value("assigned_agent_id").toString(),QString("agent-a"));
        QCOMPARE(f.task("task-a").value("project_id").toString(),QString("project-a"));
        QCOMPARE(f.task("task-a").value("status").toString(),QString("in_progress"));
        QCOMPARE(c.selectedId(),QString("task-b")); QCOMPARE(c.selectedRecord(),selected);
        QVERIFY(c.pendingTaskId().isEmpty()); QVERIFY(c.pendingTaskStatus().isEmpty());
        QCOMPARE(c.overview().value("meta").toMap().value("counts").toMap().value("to_do").toInt(),0);
        QCOMPARE(c.overview().value("meta").toMap().value("counts").toMap().value("in_progress").toInt(),1);
        QCOMPARE(result.size(),1); QCOMPARE(result.first().first().toString(),QString("move-task"));
    }
    void taskMoveFailureKeepsTaskInSourceColumn() {
        TaskFixture f; auto& c=*f.controller;
        QTRY_COMPARE(c.allRecords().size(),2); const auto original=f.task("task-a");
        f.intercept=[&](QTcpSocket* socket,const QString&) {
            if (f.remote.methods.last()!="PATCH") return false;
            LocalApi::reply(socket,R"({"error":{"message":"This workspace is read-only."}})",403); return true;
        };
        QSignalSpy result(&c,&FeatureController::actionResult);
        QVERIFY(c.moveTask("task-a","completed")); QTRY_VERIFY(!c.busy());
        QCOMPARE(f.task("task-a"),original); QVERIFY(c.error().contains("read-only"));
        QVERIFY(c.pendingTaskId().isEmpty()); QCOMPARE(result.size(),0);
    }
    void taskMoveRejectsReadOnlyOfflineUnknownAndUnchangedTasks() {
        TaskFixture f; auto& c=*f.controller;
        QTRY_COMPARE(c.allRecords().size(),2);
        f.canUpdate=false; c.refresh(); QTRY_VERIFY(!c.busy());
        auto requests=f.remote.paths.size(); QVERIFY(!c.canMoveTasks());
        QVERIFY(!c.moveTask("task-a","completed")); QCOMPARE(f.remote.paths.size(),requests);
        f.canUpdate=true; c.refresh(); QTRY_VERIFY(!c.busy());
        f.api.setOnline(false); requests=f.remote.paths.size();
        QVERIFY(!c.canMoveTasks()); QVERIFY(!c.moveTask("task-a","completed")); QCOMPARE(f.remote.paths.size(),requests);
        f.api.setOnline(true); QVERIFY(c.canMoveTasks());
        QVERIFY(!c.moveTask("unknown-task","completed")); QVERIFY(!c.moveTask("task-a","unknown-status"));
        QVERIFY(!c.moveTask("task-a","to_do")); QCOMPARE(f.remote.paths.size(),requests);
        QVERIFY(!c.moveTask("../task-a","completed")); QCOMPARE(f.remote.paths.size(),requests);
        QCOMPARE(f.task("task-a").value("status").toString(),QString("to_do"));
    }
    void taskMoveSupportsEveryExplicitStatusAndPreservesSelectedDiscussion() {
        TaskFixture f; auto& c=*f.controller;
        QTRY_COMPARE(c.allRecords().size(),2); c.select("task-a");
        QTRY_VERIFY(c.selectedRecord().contains("comments"));
        for (const auto* status : {"in_progress","in_review","waiting","blocked","overdue","completed","canceled","to_do"}) {
            QVERIFY(c.moveTask("task-a",status)); QTRY_VERIFY(!c.busy());
            QCOMPARE(c.selectedRecord().value("status").toString(),QString::fromLatin1(status));
            QCOMPARE(c.details().value("status").toString(),QString::fromLatin1(status));
            QCOMPARE(c.selectedRecord().value("comments").toList().size(),1);
        }
        c.submit("runs",{}); QTRY_VERIFY(!c.busy());
        const auto report=c.details(); QVERIFY(!c.showingRecordDetails());
        QVERIFY(c.moveTask("task-a","in_progress")); QTRY_VERIFY(!c.busy());
        QCOMPARE(c.details(),report); QCOMPARE(c.selectedRecord().value("status").toString(),QString("in_progress"));
        c.showRecordDetails(); QCOMPARE(c.details().value("status").toString(),QString("in_progress"));
    }
    void taskMoveRejectsConcurrentMoveAndClearsPendingOnNavigation() {
        TaskFixture f; auto& c=*f.controller; QPointer<QTcpSocket> pending;
        QTRY_COMPARE(c.allRecords().size(),2);
        f.intercept=[&](QTcpSocket* socket,const QString&) {
            if (f.remote.methods.last()!="PATCH") return false;
            pending=socket; return true;
        };
        QVERIFY(c.moveTask("task-a","in_progress")); QTRY_VERIFY(pending);
        const auto requests=f.remote.paths.size();
        QVERIFY(!c.moveTask("task-b","completed")); QCOMPARE(f.remote.paths.size(),requests);
        c.navigate("projects"); QTRY_VERIFY(!c.busy());
        QVERIFY(c.pendingTaskId().isEmpty()); QVERIFY(c.pendingTaskStatus().isEmpty());
        QVERIFY(c.currentMemberId().isEmpty()); QVERIFY(!c.canMoveTasks());
        QCOMPARE(c.currentPage(),QString("projects")); QVERIFY(c.allRecords().isEmpty());
    }
    void taskMoveRejectsMalformedConfirmationWithoutChangingRecord() {
        TaskFixture f; auto& c=*f.controller;
        QTRY_COMPARE(c.allRecords().size(),2); const auto original=f.task("task-a");
        f.intercept=[&](QTcpSocket* socket,const QString&) {
            if (f.remote.methods.last()!="PATCH") return false;
            LocalApi::reply(socket,R"({"data":{"id":"task-b","status":"completed"}})"); return true;
        };
        QVERIFY(c.moveTask("task-a","completed")); QTRY_VERIFY(!c.busy());
        QCOMPARE(f.task("task-a"),original); QVERIFY(c.error().contains("did not confirm"));
    }
    void avatarGenerationTextPollsAndRetainsCompletedAsset() {
        LocalApi remote;
        remote.handler=[&](QTcpSocket* socket,const QString& path) {
            if (remote.methods.last()=="POST") LocalApi::reply(socket,R"({"data":{"id":"gen-one","mode":"text","status":"generating","progress":18}})",202);
            else if (path=="/api/avatar-generations/gen-one") LocalApi::reply(socket,R"({"data":{"id":"gen-one","mode":"text","status":"ready","progress":100,"asset_id":"custom-asset"}})");
            else LocalApi::reply(socket,R"({"data":[]})");
        };
        ApiClient api(remote.origin()); api.setSession("test-token","alice",false); api.setWorkspace("workspace-a");
        PhoenixClient realtime; SessionController session(api,realtime);
        AvatarGenerationController avatars(api,session);
        avatars.generateText("  An architect wearing blue, full body.  ","Ada");
        QTRY_COMPARE(avatars.current().value("status").toString(),QString("generating"));
        QCOMPARE(remote.paths.front(),QString("/api/avatar-generations"));
        QCOMPARE(remote.bodies.front().value("mode").toString(),QString("text"));
        QCOMPARE(remote.bodies.front().value("prompt").toString(),QString("An architect wearing blue, full body."));
        QCOMPARE(remote.bodies.front().value("name").toString(),QString("Ada"));
        avatars.refreshCurrent();
        QTRY_COMPARE(avatars.current().value("status").toString(),QString("ready"));
        QCOMPARE(avatars.current().value("asset_id").toString(),QString("custom-asset"));
        QCOMPARE(avatars.generations().size(),1);
        QCOMPARE(avatars.generations().front().toMap().value("asset_id").toString(),QString("custom-asset"));
        api.setWorkspace("workspace-b"); avatars.refresh();
        QVERIFY(avatars.current().isEmpty()); QVERIFY(avatars.generations().isEmpty());
        QTRY_VERIFY(!avatars.refreshing());
    }
    void avatarGenerationValidatesImageAndUsesSingleFileMultipart() {
        LocalApi remote; QByteArray upload;
        remote.handler=[&](QTcpSocket* socket,const QString&) {
            upload=socket->property("request").toByteArray();
            LocalApi::reply(socket,R"({"data":{"id":"image-gen","mode":"image","status":"queued","progress":0}})",202);
        };
        ApiClient api(remote.origin()); api.setSession("test-token","alice",false); api.setWorkspace("workspace-a");
        PhoenixClient realtime; SessionController session(api,realtime); AvatarGenerationController avatars(api,session);
        avatars.generateText(QString(601,'x')); QVERIFY(!avatars.error().isEmpty()); QVERIFY(remote.paths.isEmpty());
        avatars.generateImage(QUrl("https://example.test/photo.png")); QVERIFY(!avatars.error().isEmpty()); QVERIFY(remote.paths.isEmpty());
        QTemporaryDir directory; QFile file(directory.filePath("portrait.png")); QVERIFY(file.open(QIODevice::WriteOnly));
        file.write("not an image"); file.close();
        avatars.generateImage(QUrl::fromLocalFile(file.fileName())); QVERIFY(!avatars.error().isEmpty()); QVERIFY(remote.paths.isEmpty());
        QVERIFY(file.open(QIODevice::WriteOnly|QIODevice::Truncate));
        file.write("RIFF0000WEBP"); file.close();
        avatars.generateImage(QUrl::fromLocalFile(file.fileName())); QVERIFY(!avatars.error().isEmpty()); QVERIFY(remote.paths.isEmpty());
        QVERIFY(file.open(QIODevice::WriteOnly|QIODevice::Truncate));
        file.write(QByteArray::fromHex("89504e470d0a1a0a00000000")); QVERIFY(file.resize(10000001)); file.close();
        avatars.generateImage(QUrl::fromLocalFile(file.fileName())); QVERIFY(!avatars.error().isEmpty()); QVERIFY(remote.paths.isEmpty());
        QVERIFY(file.open(QIODevice::WriteOnly|QIODevice::Truncate));
        file.write(QByteArray::fromHex("89504e470d0a1a0a00000000")); file.close();
        avatars.generateImage(QUrl::fromLocalFile(file.fileName()),"My teammate");
        QTRY_COMPARE(avatars.current().value("id").toString(),QString("image-gen"));
        QVERIFY(upload.contains("name=\"file\"; filename=\"portrait.png\""));
        QVERIFY(!upload.contains("name=\"files[]\""));
        QVERIFY(upload.contains("name=\"mode\"\r\n\r\nimage"));
        QVERIFY(avatars.error().isEmpty());
    }
    void avatarGenerationRestoresPendingJobsAndKeepsErrorsRecoverable() {
        LocalApi remote;
        remote.handler=[&](QTcpSocket* socket,const QString& path) {
            if (path.startsWith("/api/assets-3d")) LocalApi::reply(socket,R"({"data":[{"id":"catalog-character","kind":"character"}]})");
            else if (path=="/api/avatar-generations") LocalApi::reply(socket,R"({"data":[{"id":"existing-gen","status":"rigging","progress":72}]})");
            else LocalApi::reply(socket,R"({"data":{"id":"existing-gen","status":"failed","progress":72,"error":"The image could not be rigged."}})");
        };
        ApiClient api(remote.origin()); api.setSession("test-token","alice",false); api.setWorkspace("workspace-a");
        PhoenixClient realtime; SessionController session(api,realtime); AvatarGenerationController avatars(api,session);
        avatars.refresh(); QTRY_VERIFY(!avatars.refreshing());
        QTRY_COMPARE(avatars.catalog().size(),1);
        QCOMPARE(avatars.current().value("id").toString(),QString("existing-gen"));
        avatars.refreshCurrent(); QTRY_COMPARE(avatars.current().value("status").toString(),QString("failed"));
        QCOMPARE(avatars.current().value("error").toString(),QString("The image could not be rigged."));
        api.setOnline(false); avatars.generateText("An architect");
        QVERIFY(avatars.error().contains("Connect"));
        QCOMPARE(avatars.current().value("id").toString(),QString("existing-gen"));
    }
    void richPresentationDataKeepsRealValuesAndFiltersNestedCredentials() {
        LocalApi remote;
        remote.handler=[](QTcpSocket* socket,const QString&) {
            LocalApi::reply(socket,R"({"data":[{"id":"agent-a","display_name":"Avery","status":"idle","skills":[{"name":"Research","level":72,"api_key":"hidden"}],"avatar_config":{"primary_color":"violet","credential":"hidden"},"token_usage":42},{"id":"agent-b","display_name":"Orion","status":"active"}],"meta":{"counts":{"total":2},"access_token":"hidden"}})");
        };
        ApiClient api(remote.origin()); api.setSession("test-alice","alice",false); api.setWorkspace("workspace-a");
        PhoenixClient realtime; SessionController session(api,realtime); QTemporaryDir directory;
        CacheStore cache(directory.path()); FeatureController controller(api,session,cache);
        controller.navigate("agents"); QTRY_COMPARE(controller.allRecords().size(),2);
        const auto first=controller.allRecords().first().toMap();
        QCOMPARE(first.value("_rowId").toString(),QString("agent-a"));
        QCOMPARE(first.value("skills").toList().first().toMap().value("level").toInt(),72);
        QVERIFY(!first.value("skills").toList().first().toMap().contains("api_key"));
        QVERIFY(!first.value("avatar_config").toMap().contains("credential"));
        QCOMPARE(first.value("token_usage").toInt(),42);
        QCOMPARE(controller.overview().value("meta").toMap().value("counts").toMap().value("total").toInt(),2);
        QVERIFY(!controller.overview().value("meta").toMap().contains("access_token"));
        QSignalSpy changes(&controller,&FeatureController::changed);
        controller.search("Research"); QCOMPARE(controller.visibleRecords().size(),1);
        QCOMPARE(controller.visibleRecords().first().toMap().value("_rowId").toString(),QString("agent-a"));
        controller.search("hidden"); QCOMPARE(controller.visibleRecords().size(),0);
        controller.search("Orion");
        QCOMPARE(controller.visibleRecords().size(),1); QCOMPARE(controller.allRecords().size(),2);
        QCOMPARE(controller.visibleRecords().first().toMap().value("_rowId").toString(),QString("agent-b"));
        QVERIFY(!changes.isEmpty());
        QVERIFY(controller.selectedRecord().isEmpty());
    }
    void agentSelectionLoadsOnlyThatAgentsTasks_data() {
        QTest::addColumn<QString>("page");
        QTest::newRow("agents") << QString("agents");
        QTest::newRow("office") << QString("office");
        QTest::newRow("agent-detail") << QString("agent-detail");
    }
    void agentSelectionLoadsOnlyThatAgentsTasks() {
        QFETCH(QString,page);
        LocalApi remote;
        remote.handler=[](QTcpSocket* socket,const QString& path) {
            if (path.startsWith("/api/tasks?")) {
                LocalApi::reply(socket,R"({"data":[{"id":"task-a","assigned_agent_id":"agent-a","status":"in_progress","progress_percent":40},{"id":"task-b","assigned_agent_id":"agent-b","status":"completed","progress_percent":100},{"id":"task-c","assigned_agent_id":"agent-a","status":"completed","progress_percent":100}]})");
                return;
            }
            if (path.startsWith("/api/knowledge?")) {
                LocalApi::reply(socket,R"({"data":[{"id":"file-a","agent_id":"agent-a","title":"Contract references","indexing_status":"ready","api_key":"private"},{"id":"file-b","agent_id":"agent-b","title":"Research"},{"id":"shared","agent_id":null,"title":"Workspace notes"}]})");
                return;
            }
            if (path.startsWith("/api/agents/")) {
                const auto id=path.section('/',3,3);
                LocalApi::reply(socket,QByteArray("{\"data\":{\"id\":\"")+id.toUtf8()+"\",\"display_name\":\"Avery\",\"status\":\"idle\"}}");
                return;
            }
            LocalApi::reply(socket,R"({"data":[{"id":"agent-a","display_name":"Avery","status":"idle"},{"id":"agent-b","display_name":"Orion","status":"active"}]})");
        };
        ApiClient api(remote.origin()); api.setSession("test-alice","alice",false); api.setWorkspace("workspace-a");
        PhoenixClient realtime; SessionController session(api,realtime); QTemporaryDir directory;
        CacheStore cache(directory.path()); FeatureController controller(api,session,cache);
        controller.navigate(page); QTRY_COMPARE(controller.allRecords().size(),2);
        QCOMPARE(controller.selectedAgentTasksState(),QString("idle"));
        QCOMPARE(controller.selectedAgentKnowledgeState(),QString("idle"));
        controller.select("agent-a");
        QTRY_COMPARE(controller.selectedAgentTasksState(),QString("ready"));
        QCOMPARE(controller.selectedAgentTasks().size(),2);
        QVERIFY(remote.paths.contains("/api/tasks?agent_id=agent-a"));
        QTRY_COMPARE(controller.selectedAgentKnowledgeState(),QString("ready"));
        QCOMPARE(controller.selectedAgentKnowledge().size(),1);
        QCOMPARE(controller.selectedAgentKnowledge().first().toMap().value("title").toString(),QString("Contract references"));
        QVERIFY(!controller.selectedAgentKnowledge().first().toMap().contains("api_key"));
        QVERIFY(remote.paths.contains("/api/knowledge?agent_id=agent-a"));
        controller.select("agent-b");
        QTRY_COMPARE(controller.selectedAgentTasks().size(),1);
        QCOMPARE(controller.selectedAgentTasks().first().toMap().value("id").toString(),QString("task-b"));
        QTRY_COMPARE(controller.selectedAgentKnowledgeState(),QString("ready"));
        QCOMPARE(controller.selectedAgentKnowledge().first().toMap().value("id").toString(),QString("file-b"));
        controller.clearSelection();
        QCOMPARE(controller.selectedAgentTasksState(),QString("idle"));
        QVERIFY(controller.selectedAgentTasks().isEmpty());
        QCOMPARE(controller.selectedAgentKnowledgeState(),QString("idle"));
        QVERIFY(controller.selectedAgentKnowledge().isEmpty());
        controller.openRecord("agent-performance","agent-a");
        QTRY_COMPARE(controller.currentPage(),QString("agent-performance"));
        QTRY_COMPARE(controller.selectedAgentTasksState(),QString("ready"));
        QCOMPARE(controller.selectedAgentTasks().size(),2);
        controller.openMarketplaceOffer("agent-a","lease");
        QCOMPARE(controller.currentPage(),QString("agent-performance"));
        QVERIFY(controller.error().contains("rent"));
        QVERIFY(controller.pendingOfferAgentId().isEmpty());
        controller.openMarketplaceOffer("agent-a","sale");
        QTRY_COMPARE(controller.currentPage(),QString("marketplace"));
        QCOMPARE(controller.pendingOfferMode(),QString("sale"));
        QCOMPARE(controller.pendingOfferAgentId(),QString("agent-a"));
    }
    void agentPrimaryDetailsSurviveReportsAndSettingsRefresh() {
        LocalApi remote;
        QPointer<QTcpSocket> detailSocket;
        QPointer<QTcpSocket> refreshSocket;
        bool holdList=false;
        remote.handler=[&](QTcpSocket* socket,const QString& path) {
            if (path=="/api/agents") {
                if (holdList) refreshSocket=socket;
                else LocalApi::reply(socket,R"({"data":[{"id":"agent-a","display_name":"Avery"}]})");
            } else if (path=="/api/agents/agent-a/progression") {
                LocalApi::reply(socket,R"({"data":{"level":8,"missions_completed":42}})");
            } else if (path=="/api/agents/agent-a" && remote.methods.last()=="PATCH") {
                holdList=true;
                LocalApi::reply(socket,R"({"data":{"id":"agent-a","display_name":"Avery","instructions":"Updated instructions","autonomy_mode":"supervised"}})");
            } else if (path=="/api/agents/agent-a") detailSocket=socket;
            else LocalApi::reply(socket,R"({"data":[]})");
        };
        ApiClient api(remote.origin()); api.setSession("test-alice","alice",false); api.setWorkspace("workspace-a");
        PhoenixClient realtime; SessionController session(api,realtime); QTemporaryDir directory;
        CacheStore cache(directory.path()); FeatureController controller(api,session,cache);
        controller.navigate("office"); QTRY_COMPARE(controller.allRecords().size(),1);
        controller.select("agent-a"); QTRY_VERIFY(detailSocket);
        controller.submit("progression",{}); QTRY_VERIFY(!controller.busy());
        QCOMPARE(controller.details().value("level").toInt(),8);
        LocalApi::reply(detailSocket,R"({"data":{"id":"agent-a","display_name":"Avery","instructions":"Original instructions","autonomy_mode":"balanced","skills":["Legal research"]}})");
        QTRY_COMPARE(controller.selectedRecord().value("instructions").toString(),QString("Original instructions"));
        QCOMPARE(controller.details().value("level").toInt(),8);
        QVERIFY(!controller.details().contains("instructions"));

        QSignalSpy saved(&controller,&FeatureController::actionSucceeded);
        controller.submit("edit",{{"display_name","Avery"},{"instructions","Updated instructions"},{"autonomy_mode","supervised"}});
        QTRY_COMPARE(saved.size(),1);
        QCOMPARE(controller.selectedRecord().value("instructions").toString(),QString("Updated instructions"));
        QCOMPARE(controller.selectedRecord().value("skills").toList().size(),1);
        QTRY_VERIFY(refreshSocket);
        detailSocket=nullptr;
        LocalApi::reply(refreshSocket,R"({"data":[{"id":"agent-a","display_name":"Avery"}]})");
        QTRY_VERIFY(detailSocket);
        QCOMPARE(controller.selectedRecord().value("instructions").toString(),QString("Updated instructions"));
        QCOMPARE(controller.selectedRecord().value("autonomy_mode").toString(),QString("supervised"));
        QCOMPARE(controller.selectedRecord().value("skills").toList().size(),1);
        LocalApi::reply(detailSocket,R"({"data":{"id":"agent-a","display_name":"Avery","instructions":"Updated instructions"}})");
        controller.clearSelection();
    }
    void agentResourceResponsesCannotCrossSelections() {
        LocalApi remote;
        QPointer<QTcpSocket> oldTasks,oldKnowledge;
        remote.handler=[&](QTcpSocket* socket,const QString& path) {
            if (path=="/api/tasks?agent_id=agent-a") oldTasks=socket;
            else if (path=="/api/knowledge?agent_id=agent-a") oldKnowledge=socket;
            else if (path=="/api/tasks?agent_id=agent-b") LocalApi::reply(socket,R"({"data":[{"id":"task-b","assigned_agent_id":"agent-b"}]})");
            else if (path=="/api/knowledge?agent_id=agent-b") LocalApi::reply(socket,R"({"data":[{"id":"file-b","agent_id":"agent-b"}]})");
            else if (path=="/api/agents") LocalApi::reply(socket,R"({"data":[{"id":"agent-a","display_name":"Avery"},{"id":"agent-b","display_name":"Orion"}]})");
            else LocalApi::reply(socket,QJsonDocument(QJsonObject{{"data",QJsonObject{{"id",path.section('/',3,3)}}}}).toJson());
        };
        ApiClient api(remote.origin()); api.setSession("test-alice","alice",false); api.setWorkspace("workspace-a");
        PhoenixClient realtime; SessionController session(api,realtime); QTemporaryDir directory;
        CacheStore cache(directory.path()); FeatureController controller(api,session,cache);
        controller.navigate("office"); QTRY_COMPARE(controller.allRecords().size(),2);
        controller.select("agent-a"); QTRY_VERIFY(oldTasks && oldKnowledge);
        controller.select("agent-b");
        QTRY_COMPARE(controller.selectedAgentTasksState(),QString("ready"));
        QTRY_COMPARE(controller.selectedAgentKnowledgeState(),QString("ready"));
        LocalApi::reply(oldTasks,R"({"data":[{"id":"task-a","assigned_agent_id":"agent-a"}]})");
        LocalApi::reply(oldKnowledge,R"({"data":[{"id":"file-a","agent_id":"agent-a"}]})");
        QTRY_VERIFY(oldTasks.isNull() && oldKnowledge.isNull());
        QCOMPARE(controller.selectedAgentTasks().first().toMap().value("id").toString(),QString("task-b"));
        QCOMPARE(controller.selectedAgentKnowledge().first().toMap().value("id").toString(),QString("file-b"));
    }
    void marketplaceCheckoutReportsItsOrderAndPurchasesRemainASeparateRead() {
        LocalApi remote;
        remote.handler=[](QTcpSocket* socket,const QString& path) {
            if (path=="/api/marketplace/checkout") {
                LocalApi::reply(socket,R"({"data":{"order_id":"order-a","fulfilled":true,"sale_url":null,"checkout_url":null,"api_key":"not-displayable"}})");
            } else if (path=="/api/marketplace/purchases") {
                LocalApi::reply(socket,R"({"data":[{"id":"order-a","listing_id":"listing-a","status":"fulfilled","cloned_agent_id":"clone-a"}]})");
            } else LocalApi::reply(socket,R"({"data":[{"id":"listing-a","title":"Legal specialist","mode":"rent","price_cents":2900}]})");
        };
        ApiClient api(remote.origin()); api.setSession("test-alice","alice",false); api.setWorkspace("workspace-a");
        PhoenixClient realtime; SessionController session(api,realtime); QTemporaryDir directory;
        CacheStore cache(directory.path()); FeatureController controller(api,session,cache);
        QSignalSpy results(&controller,&FeatureController::actionResult);
        QSignalSpy external(&controller,&FeatureController::requestExternal);
        controller.navigate("marketplace"); QTRY_VERIFY(!controller.busy());
        controller.submit("checkout",{{"_id","listing-a"},{"listing_id","listing-a"},{"_confirmed",true}});
        QTRY_COMPARE(results.size(),1); QTRY_VERIFY(!controller.busy());
        QCOMPARE(results.first().at(0).toString(),QString("checkout"));
        const auto result=results.first().at(1).toMap();
        QCOMPARE(result.value("order_id").toString(),QString("order-a"));
        QVERIFY(result.value("fulfilled").toBool());
        QVERIFY(!result.contains("api_key"));
        QVERIFY(external.isEmpty());
        QCOMPARE(remote.bodies.at(remote.paths.indexOf("/api/marketplace/checkout")).value("listing_id").toString(),QString("listing-a"));
        controller.submit("purchases",{}); QTRY_VERIFY(!controller.busy());
        QCOMPARE(controller.details().value("items").toList().first().toMap().value("cloned_agent_id").toString(),QString("clone-a"));
        QCOMPARE(controller.allRecords().first().toMap().value("id").toString(),QString("listing-a"));
        QCOMPARE(results.size(),2);
        QCOMPARE(results.last().at(0).toString(),QString("purchases"));
        QCOMPARE(results.last().at(1).toMap().value("items").toList().size(),1);
    }
    void actionFormContextCannotCrossFolderSelectionOrAccount() {
        DriveFixture f; auto& c=*f.controller;
        c.navigate("drive"); QTRY_VERIFY(!c.busy()); const auto rootContext=c.actionContext("create");
        c.openDriveFolder("folder-a"); QTRY_VERIFY(!c.busy()); auto requests=f.remote.paths.size();
        c.submit("create",{{"name","Must not be created"},{"_context",rootContext}});
        QCOMPARE(f.remote.paths.size(),requests); QVERIFY(c.error().contains("previous view"));
        c.select("file-a"); QTRY_COMPARE(c.details().value("kind").toString(),QString("file")); const auto selectedContext=c.actionContext("edit");
        c.select("folder-b"); QTRY_COMPARE(c.details().value("kind").toString(),QString("folder")); requests=f.remote.paths.size();
        c.submit("edit",{{"name","Must not rename another record"},{"_context",selectedContext}}); QCOMPARE(f.remote.paths.size(),requests);
        const auto aliceContext=c.actionContext("create"); f.api.setSession("test-bob","bob",false); emit f.session.changed();
        c.submit("create",{{"name","Must not cross account"},{"_context",aliceContext}}); QCOMPARE(f.remote.paths.size(),requests);
    }
    void driveHierarchyUsesPrimaryRowsBreadcrumbsAndCurrentParent() {
        DriveFixture f; QVERIFY(f.remote.server.isListening()); auto& c=*f.controller;
        QAbstractItemModelTester modelCheck(c.records(),QAbstractItemModelTester::FailureReportingMode::QtTest);
        c.navigate("drive"); QTRY_COMPARE(c.records()->rowCount(),1);
        c.openDriveFolder("file-a"); QVERIFY(c.driveFolderId().isEmpty());
        c.openDriveFolder("folder-a"); QTRY_COMPARE(c.records()->rowCount(),2);
        QCOMPARE(c.driveFolderId(),QString("folder-a")); QCOMPARE(c.driveBreadcrumbs().size(),2); QVERIFY(c.driveCanGoBack());
        for (const auto& value : c.fieldsForAction("create")) if (value.toMap().value("key")=="parent_id")
            QCOMPARE(value.toMap().value("value").toString(),QString("folder-a"));
        c.submit("create",{{"name","Nested folder"}}); QTRY_VERIFY(!c.busy()); QCOMPARE(c.records()->rowCount(),3);
        const auto created=f.remote.methods.indexOf("POST"); QVERIFY(created>=0);
        QCOMPARE(f.remote.paths[created],QString("/api/drive")); QCOMPARE(f.remote.bodies[created].value("parent_id").toString(),QString("folder-a"));
        c.select("folder-b"); QTRY_COMPARE(c.details().value("id").toString(),QString("folder-b"));
        c.submit("children",{}); QTRY_VERIFY(!c.busy()); QCOMPARE(c.records()->rowCount(),0); QCOMPARE(c.driveFolderId(),QString("folder-b"));
        QCOMPARE(c.driveBreadcrumbs().size(),3); c.driveBack(); QTRY_COMPARE(c.records()->rowCount(),3);
        c.navigateDriveBreadcrumb(0); QTRY_COMPARE(c.records()->rowCount(),1); QVERIFY(c.driveFolderId().isEmpty()); QVERIFY(!c.driveCanGoBack());
        c.navigateDriveBreadcrumb(-1); c.navigateDriveBreadcrumb(99); QVERIFY(c.driveFolderId().isEmpty());
    }
    void driveTrashRestoresOnlySelectedTrashRowAndClearsSelection() {
        DriveFixture f; auto& c=*f.controller;
        c.navigate("drive"); QTRY_VERIFY(!c.busy()); c.openDriveFolder("folder-a"); QTRY_VERIFY(!c.busy());
        c.submit("trash",{}); QTRY_COMPARE(c.records()->rowCount(),1); QVERIFY(c.driveTrash()); QCOMPARE(c.driveFolderId(),QString("folder-a"));
        auto requests=f.remote.paths.size(); c.submit("restore",{{"_id","trash-a"}}); QCoreApplication::processEvents(); QCOMPARE(f.remote.paths.size(),requests);
        c.select("trash-a"); QTRY_COMPARE(c.details().value("status").toString(),QString("trashed"));
        requests=f.remote.paths.size(); c.submit("restore",{{"_id","file-a"}}); c.submit("create",{{"name","Forbidden in trash"}});
        c.submit("open",{}); QCoreApplication::processEvents(); QCOMPARE(f.remote.paths.size(),requests); QVERIFY(!c.driveCanDownload());
        c.submit("restore",{}); QTRY_VERIFY(!c.busy()); QCOMPARE(c.records()->rowCount(),0); QVERIFY(c.selectedId().isEmpty());
        const auto restored=f.remote.paths.indexOf("/api/drive/trash-a/restore"); QVERIFY(restored>=0); QCOMPARE(f.remote.methods[restored],QString("POST"));
        c.driveBack(); QTRY_COMPARE(c.records()->rowCount(),3); QVERIFY(!c.driveTrash()); QCOMPARE(c.driveFolderId(),QString("folder-a"));
        c.select("trash-a"); QTRY_COMPARE(c.details().value("status").toString(),QString("active"));
        requests=f.remote.paths.size(); c.submit("restore",{}); QCoreApplication::processEvents(); QCOMPARE(f.remote.paths.size(),requests);
    }
    void driveRestoreServerDenialPreservesSelectedRow() {
        DriveFixture f; auto& c=*f.controller;
        f.intercept=[](QTcpSocket* socket,const QString& path) {
            if (!path.endsWith("/restore")) return false;
            LocalApi::reply(socket,R"({"error":{"message":"Permission denied"}})",403); return true;
        };
        c.navigate("drive"); QTRY_VERIFY(!c.busy()); c.setDriveTrash(true); QTRY_VERIFY(!c.busy()); c.select("trash-a");
        QTRY_COMPARE(c.details().value("status").toString(),QString("trashed")); c.submit("restore",{});
        QTRY_VERIFY(!c.busy()); QVERIFY(!c.error().isEmpty()); QCOMPARE(c.selectedId(),QString("trash-a")); QCOMPARE(c.records()->rowCount(),1);
    }
    void driveOfflineNavigationUsesExactPartitionAndBlocksMutations() {
        DriveFixture f; auto& c=*f.controller;
        c.navigate("drive"); QTRY_VERIFY(!c.busy()); c.openDriveFolder("folder-a"); QTRY_VERIFY(!c.busy());
        c.setDriveTrash(true); QTRY_VERIFY(!c.busy()); c.driveBack(); QTRY_VERIFY(!c.busy());
        f.api.setOnline(false); const auto requests=f.remote.paths.size();
        c.navigateDriveBreadcrumb(0); QTRY_VERIFY(!c.busy()); QCOMPARE(c.records()->rowCount(),1); QVERIFY(c.offline());
        c.openDriveFolder("folder-a"); QTRY_VERIFY(!c.busy()); QCOMPARE(c.records()->rowCount(),2);
        c.setDriveTrash(true); QTRY_VERIFY(!c.busy()); QCOMPARE(c.records()->rowCount(),1);
        c.select("trash-a"); c.submit("restore",{}); QCOMPARE(f.remote.paths.size(),requests); QVERIFY(!c.error().isEmpty());
        f.api.setWorkspace("workspace-b"); emit f.session.changed(); c.refresh(); QTRY_VERIFY(!c.busy());
        QVERIFY(c.driveFolderId().isEmpty()); QVERIFY(!c.driveTrash()); QCOMPARE(c.records()->rowCount(),0); QCOMPARE(f.remote.paths.size(),requests);
    }
    void driveNavigationAndAccountChangeCancelLateFolderReplies() {
        DriveFixture f; auto& c=*f.controller; QPointer<QTcpSocket> pending;
        f.intercept=[&](QTcpSocket* socket,const QString& path) { if (path!="/api/drive/folder-a/children") return false; pending=socket; return true; };
        c.navigate("drive"); QTRY_VERIFY(!c.busy()); c.openDriveFolder("folder-a"); QTRY_VERIFY(pending);
        c.driveBack(); QTRY_VERIFY(!c.busy()); QCOMPARE(c.records()->rowCount(),1); QVERIFY(c.driveFolderId().isEmpty());
        QTRY_VERIFY(!pending || pending->state()==QAbstractSocket::UnconnectedState);
        pending=nullptr; c.openDriveFolder("folder-a"); QTRY_VERIFY(pending);
        f.api.setSession("test-bob","bob",false); emit f.session.changed();
        QCOMPARE(c.records()->rowCount(),0); QVERIFY(c.driveFolderId().isEmpty()); QVERIFY(!c.driveTrash());
        QTRY_VERIFY(!pending || pending->state()==QAbstractSocket::UnconnectedState);
    }
    void driveMutationInvalidatesCachedOldLocation() {
        DriveFixture f; auto& c=*f.controller;
        c.navigate("drive"); QTRY_VERIFY(!c.busy()); c.openDriveFolder("folder-a"); QTRY_VERIFY(!c.busy());
        c.setDriveTrash(true); QTRY_VERIFY(!c.busy()); c.select("trash-a"); QTRY_COMPARE(c.details().value("status").toString(),QString("trashed"));
        c.submit("restore",{}); QTRY_VERIFY(!c.busy());
        const auto key=QString::fromStdString(mokaid::core::cacheKey(f.api.origin().toString().toStdString(),"alice","workspace-a","/api/drive/folder-a/children"));
        bool checked=false; f.cache.read(key,this,[&](QByteArray bytes) { QCOMPARE(bytes,QByteArray("null")); checked=true; }); QTRY_VERIFY(checked);
        f.api.setOnline(false);
        c.driveBack(); QTRY_VERIFY(!c.busy()); QCOMPARE(c.records()->rowCount(),0);
        QVERIFY(c.error().contains("No synchronized data"));
    }
    void driveDownloadSanitizesNamesAndRejectsLargeOrRemoteTargets() {
        QCOMPARE(DriveDownload::safeFileName("../../report.json"),QString("report.json"));
        QCOMPARE(DriveDownload::safeFileName("C:\\folder\\CON.txt"),QString("_CON.txt"));
        QCOMPARE(DriveDownload::safeFileName(QString("<b>report\u202E.txt ")),QString("_b_report.txt"));
        QCOMPARE(DriveDownload::safeFileName(".."),QString("download")); QVERIFY(DriveDownload::safeFileName(QString(400,QChar(0x00E9))).toUtf8().size()<=180);
        QCOMPARE(DriveDownload::safeFileName(QString(1000000,'x')).size(),180);
        DriveFixture f; auto& d=f.download(); QSignalSpy requested(&d,&DriveDownload::saveRequested);
        auto record=f.items["file-a"].toVariantMap(); record.insert("size_bytes",32*1024*1024+1); d.request(record);
        QCOMPARE(requested.size(),0); QVERIFY(d.error().contains("32 MiB"));
        record.insert("size_bytes",12); d.request(record); QCOMPARE(requested.size(),1);
        d.save(requested.last()[0].toString(),QUrl("file://untrusted-server/share/report.json"));
        QVERIFY(!d.error().isEmpty()); QCOMPARE(f.remote.paths.size(),0); QVERIFY(!d.busy());
    }
    void driveDownloadSavesOpaqueJsonAtomicallyAndIsSingleUse() {
        DriveFixture f; auto& d=f.download(); const auto path=f.directory.path()+"/report.json";
        const QByteArray payload("[\"real JSON file\",3]\n");
        f.intercept=[&](QTcpSocket* socket,const QString& route) {
            if (!route.endsWith("/raw")) return false; LocalApi::reply(socket,payload); return true;
        };
        QFile old(path); QVERIFY(old.open(QIODevice::WriteOnly)); old.write("previous contents"); old.close();
        QSignalSpy requested(&d,&DriveDownload::saveRequested); d.request(f.items["file-a"].toVariantMap());
        QCOMPARE(requested.size(),1); const auto transaction=requested[0][0].toString();
        d.save(transaction,QUrl::fromLocalFile(path)); QTRY_VERIFY(!d.busy()); QVERIFY2(d.error().isEmpty(),qPrintable(d.error()));
        QCOMPARE(DriveFixture::contents(path),payload); QCOMPARE(d.status(),QString("File saved."));
        QCOMPARE(f.remote.paths,QStringList{"/api/drive/file-a/raw"}); d.save(transaction,QUrl::fromLocalFile(path));
        QCoreApplication::processEvents(); QCOMPARE(f.remote.paths.size(),1);
        QCOMPARE(QDir(f.directory.path()).entryList({".mokaid-download-*"},QDir::Files|QDir::Hidden).size(),0);
    }
    void driveDownloadFailureAndChangedTargetNeverOverwrite() {
        DriveFixture f; auto& d=f.download(); const auto path=f.directory.path()+"/preserved.txt";
        QFile old(path); QVERIFY(old.open(QIODevice::WriteOnly)); old.write("keep me"); old.close();
        QSignalSpy requested(&d,&DriveDownload::saveRequested);
        f.intercept=[](QTcpSocket* socket,const QString& route) {
            if (!route.endsWith("/raw")) return false; LocalApi::reply(socket,R"({"error":{"message":"No permission"}})",403); return true;
        };
        d.request(f.items["file-a"].toVariantMap()); d.save(requested.last()[0].toString(),QUrl::fromLocalFile(path)); QTRY_VERIFY(!d.busy());
        QVERIFY(!d.error().isEmpty()); QCOMPARE(DriveFixture::contents(path),QByteArray("keep me"));
        f.intercept=[&](QTcpSocket* socket,const QString& route) {
            if (!route.endsWith("/raw")) return false;
            QFile changed(path); if (changed.open(QIODevice::WriteOnly)) { changed.write("changed after confirmation"); changed.close(); }
            LocalApi::reply(socket,"download bytes",200,"application/octet-stream"); return true;
        };
        d.request(f.items["file-a"].toVariantMap()); d.save(requested.last()[0].toString(),QUrl::fromLocalFile(path)); QTRY_VERIFY(!d.busy());
        QVERIFY(d.error().contains("destination changed")); QCOMPARE(DriveFixture::contents(path),QByteArray("changed after confirmation"));
        f.intercept=[](QTcpSocket* socket,const QString& route) { if (!route.endsWith("/raw")) return false; LocalApi::reply(socket,"bytes",200,"text/plain"); return true; };
        d.request(f.items["file-a"].toVariantMap()); d.save(requested.last()[0].toString(),QUrl::fromLocalFile(f.directory.path()+"/missing-parent/file"));
        QTRY_VERIFY(!d.busy()); QVERIFY(!d.error().isEmpty()); QVERIFY(!QFileInfo::exists(f.directory.path()+"/missing-parent/file"));
        QCOMPARE(QDir(f.directory.path()).entryList({".mokaid-download-*"},QDir::Files|QDir::Hidden).size(),0);
    }
    void driveDownloadCancelAccountSwitchAndStaleDialogCannotWrite() {
        DriveFixture f; auto& d=f.download(); QPointer<QTcpSocket> pending;
        f.intercept=[&](QTcpSocket* socket,const QString& path) { if (!path.endsWith("/raw")) return false; pending=socket; return true; };
        QSignalSpy requested(&d,&DriveDownload::saveRequested); const auto path=f.directory.path()+"/must-not-exist";
        d.request(f.items["file-a"].toVariantMap()); const auto first=requested.last()[0].toString();
        d.save(first,QUrl::fromLocalFile(path)); QTRY_VERIFY(pending); d.cancel();
        QTRY_VERIFY(!pending || pending->state()==QAbstractSocket::UnconnectedState); QVERIFY(!QFileInfo::exists(path));
        pending=nullptr; d.request(f.items["file-a"].toVariantMap()); const auto second=requested.last()[0].toString();
        d.save(first,QUrl::fromLocalFile(path)); QVERIFY(!d.busy()); d.cancel(first); QCOMPARE(d.pendingTransaction(),second);
        d.save(second,QUrl::fromLocalFile(path)); QTRY_VERIFY(pending);
        f.api.setSession("test-bob","bob",false); emit f.session.changed();
        QTRY_VERIFY(!d.busy()); QVERIFY(d.pendingTransaction().isEmpty()); QVERIFY(!QFileInfo::exists(path));
        const auto requests=f.remote.paths.size(); d.save(second,QUrl::fromLocalFile(path)); QCOMPARE(f.remote.paths.size(),requests);
    }
    void driveDownloadCancellationBeforeAtomicCommitPreservesDestination() {
        DriveFixture f; auto& d=f.download(); const auto path=f.directory.path()+"/keep.txt";
        QFile existing(path); QVERIFY(existing.open(QIODevice::WriteOnly)); existing.write("original"); existing.close();
        f.intercept=[](QTcpSocket* socket,const QString& route) {
            if (!route.endsWith("/raw")) return false; LocalApi::reply(socket,QByteArray(1024*1024,'x'),200,"application/octet-stream"); return true;
        };
        connect(&d,&DriveDownload::changed,this,[&] {
            if (d.status()=="Saving…") { f.api.setWorkspace("other-workspace"); emit f.session.changed(); }
        });
        QSignalSpy requested(&d,&DriveDownload::saveRequested); d.request(f.items["file-a"].toVariantMap());
        d.save(requested.last()[0].toString(),QUrl::fromLocalFile(path)); QTRY_VERIFY(!d.busy());
        QCOMPARE(DriveFixture::contents(path),QByteArray("original")); QVERIFY(d.pendingTransaction().isEmpty());
    }
    void driveDownloadConnectionLossExplainsCancellationAndPreservesDestination() {
        DriveFixture f; auto& d=f.download(); const auto path=f.directory.path()+"/keep.txt";
        QFile existing(path); QVERIFY(existing.open(QIODevice::WriteOnly)); existing.write("original"); existing.close();
        f.intercept=[](QTcpSocket* socket,const QString& route) {
            if (!route.endsWith("/raw")) return false;
            socket->write("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Type: application/octet-stream\r\nContent-Length: 1000\r\n\r\nincomplete");
            socket->disconnectFromHost(); return true;
        };
        QSignalSpy requested(&d,&DriveDownload::saveRequested); d.request(f.items["file-a"].toVariantMap());
        d.save(requested.last()[0].toString(),QUrl::fromLocalFile(path)); QTRY_VERIFY(!d.busy());
        QCOMPARE(d.error(),QString("Download canceled: connection lost. Destination unchanged."));
        QCOMPARE(DriveFixture::contents(path),QByteArray("original")); QVERIFY(!f.api.context().online);
        QVERIFY(d.pendingTransaction().isEmpty());
    }
    void driveDownloadCancellationAfterSyncBeforePublication_data() {
        QTest::addColumn<QString>("change");
        for (const auto* change : {"cancel", "account", "workspace", "navigation", "connection", "new-request"})
            QTest::newRow(change) << QString(change);
    }
    void driveDownloadReentrantReplacementDoesNotStartOldNetworkOrWriter_data() {
        QTest::addColumn<QString>("phase");
        QTest::addColumn<int>("expectedRequests");
        QTest::newRow("before-network") << QString("Downloading · up to 32 MiB") << 0;
        QTest::newRow("before-writer") << QString("Saving…") << 1;
    }
    void driveDownloadReentrantReplacementDoesNotStartOldNetworkOrWriter() {
        QFETCH(QString, phase); QFETCH(int, expectedRequests);
        DriveFixture f; auto& d=f.download(); const auto path=f.directory.path()+"/never-written.txt";
        f.intercept=[](QTcpSocket* socket,const QString& route) {
            if (!route.endsWith("/raw")) return false; LocalApi::reply(socket,"old bytes"); return true;
        };
        QString nextTransaction;
        connect(&d,&DriveDownload::changed,this,[&] {
            if (d.status()!=phase) return;
            auto record=f.items["file-a"].toVariantMap(); record.insert("id","different-file");
            d.request(record); nextTransaction=d.pendingTransaction();
        });
        d.request(f.items["file-a"].toVariantMap()); const auto first=d.pendingTransaction();
        d.save(first,QUrl::fromLocalFile(path)); QTRY_VERIFY(!nextTransaction.isEmpty());
        QVERIFY(first!=nextTransaction); QCOMPARE(d.pendingTransaction(),nextTransaction); QVERIFY(!d.busy());
        QCOMPARE(f.remote.paths.size(),expectedRequests); QVERIFY(!QFileInfo::exists(path));
        QVERIFY(QDir(f.directory.path()).entryList({".mokaid-download-*"},QDir::Files|QDir::Hidden).isEmpty());
    }
    void driveDownloadCancellationAfterSyncBeforePublication() {
        QFETCH(QString, change);
        DriveFixture f; auto& d=f.download(); const auto path=f.directory.path()+"/unchanged.txt";
        QFile existing(path); QVERIFY(existing.open(QIODevice::WriteOnly)); QCOMPARE(existing.write("original"),8); existing.close();
        f.intercept=[](QTcpSocket* socket,const QString& route) {
            if (!route.endsWith("/raw")) return false; LocalApi::reply(socket,QByteArray(1024*1024,'x'),200,"application/octet-stream"); return true;
        };
        bool finalized=false; QString nextTransaction;
        connect(&d,&DriveDownload::changed,this,[&] {
            if (d.status()!="Finalizing…") return;
            finalized=true;
            if (change=="cancel") d.cancel();
            else if (change=="account") { f.api.setSession("test-bob","bob",false); emit f.session.changed(); }
            else if (change=="workspace") { f.api.setWorkspace("other-workspace"); emit f.session.changed(); }
            else if (change=="navigation") f.controller->navigate("drive");
            else if (change=="connection") f.api.setOnline(false);
            else { d.request(f.items["file-a"].toVariantMap()); nextTransaction=d.pendingTransaction(); }
        });
        d.request(f.items["file-a"].toVariantMap()); const auto transaction=d.pendingTransaction();
        d.save(transaction,QUrl::fromLocalFile(path)); QTRY_VERIFY(finalized); QTRY_VERIFY(!d.busy());
        QCOMPARE(DriveFixture::contents(path),QByteArray("original"));
        QTRY_COMPARE(QDir(f.directory.path()).entryList({".mokaid-download-*"},QDir::Files|QDir::Hidden).size(),0);
        if (change=="new-request") { QVERIFY(!nextTransaction.isEmpty()); QCOMPARE(d.pendingTransaction(),nextTransaction); QVERIFY(nextTransaction!=transaction); }
        else QVERIFY(d.pendingTransaction().isEmpty());
        if (change=="connection") QCOMPARE(d.error(),QString("Download canceled: connection lost. Destination unchanged."));
    }
    void driveDownloadDestinationChangedAfterSyncIsNotReplaced() {
        DriveFixture f; auto& d=f.download(); const auto path=f.directory.path()+"/unchanged.txt";
        QFile existing(path); QVERIFY(existing.open(QIODevice::WriteOnly)); QCOMPARE(existing.write("original"),8); existing.close();
        f.intercept=[](QTcpSocket* socket,const QString& route) {
            if (!route.endsWith("/raw")) return false; LocalApi::reply(socket,"download"); return true;
        };
        bool finalized=false;
        connect(&d,&DriveDownload::changed,this,[&] {
            if (d.status()!="Finalizing…") return;
            finalized=true; QFile changed(path);
            if (changed.open(QIODevice::WriteOnly)) { changed.write("external change after sync"); changed.close(); }
        });
        d.request(f.items["file-a"].toVariantMap()); d.save(d.pendingTransaction(),QUrl::fromLocalFile(path));
        QTRY_VERIFY(finalized); QTRY_VERIFY(!d.busy()); QVERIFY(d.error().contains("destination changed"));
        QCOMPARE(DriveFixture::contents(path),QByteArray("external change after sync"));
        QTRY_COMPARE(QDir(f.directory.path()).entryList({".mokaid-download-*"},QDir::Files|QDir::Hidden).size(),0);
    }
    void catalogSecurityBoundaries() {
        QCOMPARE(featureCatalog().size(),33);
        QVERIFY(findFeature("knowledge")==nullptr);
        QSet<QString> pages;
        int admin=0;
        for (const auto& feature : featureCatalog()) {
            QVERIFY(!pages.contains(feature.id)); pages.insert(feature.id);
            QVERIFY(feature.path.startsWith("/api/"));
            if (feature.scope==mokaid::core::Scope::administration) { ++admin; QVERIFY(feature.path.startsWith("/api/admin/")); }
            else QVERIFY(!feature.path.startsWith("/api/admin/"));
            QSet<QString> actions;
            for (const auto& action : feature.actions) {
                QVERIFY(!actions.contains(action.id)); actions.insert(action.id);
                if (action.method=="DELIVERY" || action.method=="EXTERNAL") continue;
                QVERIFY(action.path.startsWith("/api/"));
                if (action.method=="DELETE") QVERIFY(action.destructive);
                if (feature.scope==mokaid::core::Scope::administration && action.method!="GET") QVERIFY(action.destructive);
                if (action.path.contains("{id}")) QVERIFY(action.selection);
            }
        }
        QCOMPARE(admin,15);
        QVERIFY(findFeature("profile")->scope==mokaid::core::Scope::identity);
        QVERIFY(findFeature("not-a-page")==nullptr);
    }
    void parseRealEnvelopeShapes() {
        const auto array=QJsonDocument::fromJson(R"({"data":[{"id":"one","title":"Task"}],"meta":{"page":1}})").object();
        const auto rows=extractFeatureRecords(array);
        QCOMPARE(rows.size(),1);
        QCOMPARE(featureRecordId(rows.first().toMap()),QString("one"));
        const auto profile=QJsonDocument::fromJson(R"({"user":{"id":"user1","full_name":"Alex"},"workspaces":[]})").object();
        QCOMPARE(featureRecordTitle(extractFeatureRecords(profile,"user").first().toMap()),QString("Alex"));
        const auto metrics=QJsonDocument::fromJson(R"({"data":{"users_total":17,"tasks_by_status":[{"status":"completed","count":3}]}})").object();
        const auto metricRows=extractFeatureRecords(metrics);
        QCOMPARE(metricRows.size(),2);
        bool found=false;
        for (const auto& row : metricRows) if (row.toMap().value("id")=="users_total") { found=true; QCOMPARE(row.toMap().value("value").toInt(),17); }
        QVERIFY(found);
        QVERIFY(extractFeatureRecords(QJsonObject{{"data",QJsonArray{}}}).isEmpty());
    }
    void mergeMcpInstallationWithoutInventingState() {
        const auto response=QJsonDocument::fromJson(R"({"data":{"servers":[{"id":"server1","key":"github","name":"GitHub"},{"id":"server2","key":"docs","name":"Docs"}],"installations":[{"id":"installation1","server_id":"server1","status":"connected","connected_account":"alex"}]}})").object();
        const auto records=extractFeatureRecords(response,"servers");
        QCOMPARE(records.size(),2);
        QCOMPARE(records[0].toMap().value("installation_id").toString(),QString("installation1"));
        QCOMPARE(records[0].toMap().value("status").toString(),QString("connected"));
        QVERIFY(!records[1].toMap().contains("status"));
    }
    void incrementalUpdatesKeepDelegatesAndSupportFiltering() {
        RecordListModel model;
        QAbstractItemModelTester invariants(&model,QAbstractItemModelTester::FailureReportingMode::QtTest);
        QSignalSpy reset(&model,&QAbstractItemModel::modelReset);
        QSignalSpy changed(&model,&QAbstractItemModel::dataChanged);
        model.setRecords({QVariantMap{{"id","a"},{"title","Alpha"}},QVariantMap{{"id","b"},{"title","Beta"}}});
        QCOMPARE(model.rowCount(),2);
        const QPersistentModelIndex first(model.index(0));
        model.setRecords({QVariantMap{{"id","a"},{"title","Updated"}},QVariantMap{{"id","b"},{"title","Beta"}}});
        QVERIFY(first.isValid()); QCOMPARE(changed.size(),1); QCOMPARE(reset.size(),0);
        QCOMPARE(model.data(first,RecordListModel::Title).toString(),QString("Updated"));
        model.setRecords({QVariantMap{{"id","b"},{"title","Beta"}},QVariantMap{{"id","a"},{"title","Updated"}}});
        QCOMPARE(first.row(),1);
        model.setQuery("beta"); QCOMPARE(model.rowCount(),1);
        QCOMPARE(model.data(model.index(0),RecordListModel::RowId).toString(),QString("b"));
        model.setQuery({}); QCOMPARE(model.rowCount(),2);
        model.setRecords({}); QCOMPARE(model.rowCount(),0);
    }
    void actionFieldsMatchBackendContracts() {
        const auto keys=[](const QString& page,const QString& action) {
            QSet<QString> result;
            for (const auto& entry : findFeature(page)->actions) if (entry.id==action)
                for (const auto& field : entry.fields) result.insert(field.toMap().value("key").toString());
            return result;
        };
        QVERIFY(keys("mail","create-rule").contains("prompt"));
        QVERIFY(!keys("mail","create-rule").contains("instruction"));
        QVERIFY(keys("integrations","install").contains("server_url"));
        QVERIFY(!keys("integrations","install").contains("settings"));
        QVERIFY(!keys("admin-workspaces","edit").contains("slug"));
        QCOMPARE(keys("agents","transfer"),QSet<QString>{"target_workspace_id"});
    }
    void cacheIsPartitionedByServerUserAndWorkspace() {
        QTemporaryDir directory; QVERIFY(directory.isValid()); CacheStore cache(directory.path());
        const auto key=[](const char* server,const char* user,const char* workspace) {
            return QString::fromStdString(mokaid::core::cacheKey(server,user,workspace,"/api/tasks"));
        };
        const auto own=key("https://mokaid.com","alice","workspace-a");
        cache.write(own,"private task");
        int completed=0;
        cache.read(own,this,[&](QByteArray bytes) { QCOMPARE(bytes,QByteArray("private task")); ++completed; });
        for (const auto& foreign : {key("https://other.example","alice","workspace-a"),key("https://mokaid.com","bob","workspace-a"),key("https://mokaid.com","alice","workspace-b")})
            cache.read(foreign,this,[&](QByteArray bytes) { QVERIFY(bytes.isEmpty()); ++completed; });
        QTRY_COMPARE(completed,4);
    }
    void lateNetworkResponseCannotCrossAccounts() {
        LocalApi remote; QVERIFY(remote.server.isListening());
        QPointer<QTcpSocket> pending;
        remote.handler=[&](QTcpSocket* socket,const QString&) { pending=socket; };
        ApiClient api(remote.origin()); api.setSession("test-alice","alice",false); api.setWorkspace("workspace-a");
        bool completed=false;
        api.request("GET","/api/tasks",{},mokaid::core::Scope::workspace,this,[&](ApiResponse) { completed=true; });
        QTRY_VERIFY(pending);
        const auto previous=api.context().generation;
        api.setSession("test-bob","bob",false);
        QVERIFY(api.context().generation>previous);
        if (pending && pending->state()==QAbstractSocket::ConnectedState) LocalApi::reply(pending,R"({"data":[{"id":"secret"}]})");
        QTRY_VERIFY(!pending || pending->state()==QAbstractSocket::UnconnectedState);
        QCoreApplication::processEvents(); QVERIFY(!completed);
    }
    void administratorRevocationClearsMemoryAndNeverCaches() {
        LocalApi remote; QVERIFY(remote.server.isListening());
        remote.handler=[](QTcpSocket* socket,const QString&) { LocalApi::reply(socket,R"({"data":[{"id":"operator-user","full_name":"Private user"}]})"); };
        QTemporaryDir directory; QVERIFY(directory.isValid()); CacheStore cache(directory.path());
        ApiClient api(remote.origin()); PhoenixClient realtime; SessionController session(api,realtime);
        api.setSession("test-operator","operator",true);
        FeatureController controller(api,session,cache); controller.navigate("admin-users");
        QTRY_COMPARE(controller.records()->rowCount(),1);
        bool drained=false; cache.read("barrier",this,[&](QByteArray) { drained=true; }); QTRY_VERIFY(drained);
        const auto connection=QStringLiteral("feature-admin-cache-test");
        {
            auto db=QSqlDatabase::addDatabase("QSQLITE",connection); db.setDatabaseName(directory.path()+"/recent.sqlite"); QVERIFY(db.open());
            QSqlQuery query(db); QVERIFY(query.exec("SELECT count(*) FROM cache")); QVERIFY(query.next()); QCOMPARE(query.value(0).toInt(),0);
            db.close();
        }
        QSqlDatabase::removeDatabase(connection);
        remote.handler=[](QTcpSocket* socket,const QString&) { LocalApi::reply(socket,R"({"error":{"message":"Role revoked"}})",403); };
        controller.refresh();
        QTRY_COMPARE(controller.currentPage(),QString("office"));
        QCOMPARE(controller.records()->rowCount(),0); QVERIFY(controller.details().isEmpty()); QVERIFY(!session.administrator());
        for (const auto& page : controller.pages()) QVERIFY(!page.toMap().value("id").toString().startsWith("admin-"));
        controller.navigate("admin-users"); QCOMPARE(controller.currentPage(),QString("office"));
    }
    void secondaryReportsDoNotOverwriteEditDefaults() {
        LocalApi remote; QVERIFY(remote.server.isListening());
        remote.handler=[](QTcpSocket* socket,const QString& path) {
            if (path.startsWith("/api/admin/users?")) LocalApi::reply(socket,R"({"data":[{"id":"user1","full_name":"Original name"}]})");
            else if (path.endsWith("/summary")) LocalApi::reply(socket,R"({"data":{"metrics":{"missions":3}}})");
            else LocalApi::reply(socket,R"({"data":{"id":"user1","full_name":"Expanded name","locale":"fr"}})");
        };
        QTemporaryDir directory; CacheStore cache(directory.path()); ApiClient api(remote.origin());
        PhoenixClient realtime; SessionController session(api,realtime); api.setSession("test-operator","operator",true);
        FeatureController controller(api,session,cache); controller.navigate("admin-users"); QTRY_COMPARE(controller.records()->rowCount(),1);
        controller.select("user1"); QTRY_COMPARE(controller.details().value("full_name").toString(),QString("Expanded name"));
        controller.submit("summary",{}); QTRY_VERIFY(!controller.busy()); QVERIFY(controller.details().contains("metrics"));
        bool found=false;
        for (const auto& value : controller.fieldsForAction("edit")) if (value.toMap().value("key")=="full_name") {
            found=true; QCOMPARE(value.toMap().value("value").toString(),QString("Expanded name"));
        }
        QVERIFY(found);
        api.setOnline(false); QCOMPARE(controller.currentPage(),QString("office")); QCOMPARE(controller.records()->rowCount(),0);
    }
    void editingPreservesUndisclosedRelationshipIds() {
        LocalApi remote; QVERIFY(remote.server.isListening());
        remote.handler=[](QTcpSocket* socket,const QString&) { LocalApi::reply(socket,R"({"data":[{"id":"member1","title":"Engineer","status":"active"}]})"); };
        QTemporaryDir directory; CacheStore cache(directory.path()); ApiClient api(remote.origin());
        PhoenixClient realtime; SessionController session(api,realtime); api.setSession("test-operator","operator",true);
        FeatureController controller(api,session,cache); controller.navigate("admin-members"); QTRY_COMPARE(controller.records()->rowCount(),1);
        controller.select("member1");
        controller.submit("edit",{{"title","Lead"},{"status","active"},{"role_id",""},{"_confirmed",true}});
        QTRY_VERIFY(remote.paths.size()>=2);
        QCOMPARE(remote.bodies[1].value("title").toString(),QString("Lead"));
        QVERIFY(!remote.bodies[1].contains("role_id"));
        QTRY_VERIFY(!controller.busy());
    }
    void sensitiveCreditRetriesKeepOneIdempotencyKey() {
        LocalApi remote; QVERIFY(remote.server.isListening());
        remote.handler=[](QTcpSocket* socket,const QString& path) {
            if (path.startsWith("/api/admin/credits/transactions")) LocalApi::reply(socket,R"({"data":[]})");
            else LocalApi::reply(socket,R"({"error":{"message":"Retry later"}})",503);
        };
        QTemporaryDir directory; CacheStore cache(directory.path()); ApiClient api(remote.origin());
        PhoenixClient realtime; SessionController session(api,realtime); api.setSession("test-operator","operator",true);
        FeatureController controller(api,session,cache); controller.navigate("admin-credits"); QTRY_VERIFY(!controller.busy());
        QVariantMap values{{"workspace_id","workspace-a"},{"amount",10},{"reason","Refund"}};
        controller.submit("adjust",values); QCOMPARE(remote.paths.size(),1); QVERIFY(!controller.error().isEmpty());
        values.insert("_confirmed",true);
        controller.submit("adjust",values); QTRY_COMPARE(remote.paths.size(),2); QTRY_VERIFY(!controller.busy());
        const auto first=remote.bodies[1].value("idempotency_key").toString(); QVERIFY(!first.isEmpty());
        controller.submit("adjust",values); QTRY_COMPARE(remote.paths.size(),3); QTRY_VERIFY(!controller.busy());
        QCOMPARE(remote.bodies[2].value("idempotency_key").toString(),first);
        values.insert("amount",20);
        controller.submit("adjust",values); QTRY_COMPARE(remote.paths.size(),4); QTRY_VERIFY(!controller.busy());
        QVERIFY(remote.bodies[3].value("idempotency_key").toString()!=first);
    }
    void nestedTaskDetailsExposeAttachmentsAndFullTextWithoutRawObjects() {
        DetailBrowser browser; QAbstractItemModelTester modelCheck(browser.rows(),QAbstractItemModelTester::FailureReportingMode::QtTest);
        const QString fullText=QString(4095,'x')+QString::fromUtf8("🙂")+QString(6000,'x')+"<script>plain text only</script>";
        browser.setDocument({{"subtasks",QVariantList{QVariantMap{{"id","sub1"},{"title","Research"},{"done",true}}}},
            {"comments",QVariantList{QVariantMap{{"id","comment1"},{"author_name","Alice"},{"body",fullText}}}},
            {"attachments",QVariantList{QVariantMap{{"id","file1"},{"name","Report.html"},{"mime_type","text/html"},{"access_token","never-visible"}}}},
            {"latest_run",QVariantMap{{"token_usage",QVariantMap{{"input_tokens",12},{"output_tokens",8}}},{"plan",QVariantList{QVariantMap{{"content","Draft"},{"status","completed"}}}}}}},
            "task:1","Record details","tasks");
        QCOMPARE(browser.rows()->rowCount(),4);
        browser.enter(detailRow(browser,"attachments")); QCOMPARE(browser.rows()->rowCount(),1);
        QSignalSpy delivery(&browser,&DetailBrowser::deliveryRequested); browser.openFile(detailRow(browser,"0"));
        QCOMPARE(delivery.size(),1); QCOMPARE(delivery.first().first().toMap().value("id").toString(),QString("file1"));
        QVERIFY(!delivery.first().first().toMap().contains("access_token"));
        browser.enter(detailRow(browser,"0")); QVERIFY(detailRow(browser,"access_token").isEmpty());
        browser.goTo(0); browser.enter(detailRow(browser,"comments")); browser.enter(detailRow(browser,"0")); browser.enter(detailRow(browser,"body"));
        QCOMPARE(browser.rows()->rowCount(),3);
        QString restored;
        for (int i=0;i<browser.rows()->rowCount();++i) {
            const auto chunk=browser.rows()->data(browser.rows()->index(i,0),RecordListModel::Record).toMap().value("text").toString();
            QVERIFY(!chunk.front().isLowSurrogate()); QVERIFY(!chunk.back().isHighSurrogate()); restored+=chunk;
        }
        QCOMPARE(restored,fullText);
        QVERIFY(browser.canGoBack()); browser.goTo(0); QVERIFY(!browser.canGoBack());
        browser.enter(detailRow(browser,"latest_run")); browser.enter(detailRow(browser,"token_usage")); QCOMPARE(browser.rows()->rowCount(),2);
    }
    void managedRuntimeManifestUsesSavedDeliverablesAndDeduplicatesAttachments() {
        DetailBrowser browser;
        const QVariantMap file{{"id", "saved-report"}, {"filename", "audit.pdf"}, {"mime_type", "application/pdf"}};
        const QVariantMap manifestFile{{"id", "saved-report"}, {"filename", "audit.pdf"}};
        const QVariantMap runtime{{"engine", "openai_agents"}, {"manifest", QVariantList{manifestFile}},
            {"participants", QVariantList{QVariantMap{{"agent_id", "sira"}, {"artifacts", QStringList{"audit.pdf"}}}}}};
        browser.setDocument({{"attachments", QVariantList{file}}, {"latest_run", QVariantMap{{"output", QVariantMap{{"runtime", runtime}}}}}}, "task:runtime", "Task", "tasks");
        const auto files = browser.deliverables();
        QCOMPARE(files.size(), 1);
        QCOMPARE(files.first().toMap().value("id").toString(), QString("saved-report"));
        QCOMPARE(files.first().toMap().value("name").toString(), QString("audit.pdf"));
        browser.setDocument({{"latest_run", QVariantMap{{"output", QVariantMap{{"runtime", runtime}}}}}}, "task:manifest", "Task", "tasks");
        QCOMPARE(browser.deliverables().size(), 1);
    }
    void deliverablesAreCuratedDeduplicatedAndSeparateFromInputs() {
        DetailBrowser browser;
        const QVariantMap report{{"id","report1"},{"name","Report.pdf"},{"mime_type","application/pdf"},
            {"source","output"},{"access_token","never-visible"},{"storage_key","private-storage"}};
        const QVariantMap input{{"id","input1"},{"name","Source.csv"},{"mime_type","text/csv"},{"source","input"}};
        const QVariantMap image{{"drive_item_id","image1"},{"name","Hero.png"},{"mime_type","image/png"},
            {"size_bytes",1024},{"credentials",QVariantMap{{"secret","hidden"}}}};
        browser.setDocument({{"attachments",QVariantList{input,report}},
            {"latest_run",QVariantMap{{"output",QVariantMap{{"files",QVariantList{report,image}}}}}},
            {"metadata",QVariantMap{{"files",QVariantList{input}}}}},"task:1","Details","tasks");
        const auto files=browser.deliverables(); QCOMPARE(files.size(),2);
        QCOMPARE(files[0].toMap().value("id").toString(),QString("report1"));
        QCOMPARE(files[1].toMap().value("id").toString(),QString("image1"));
        QVERIFY(!files[0].toMap().contains("access_token")); QVERIFY(!files[0].toMap().contains("storage_key"));
        QVERIFY(!files[1].toMap().contains("credentials"));
        browser.setDocument(report,"drive:1","Details","drive"); QCOMPARE(browser.deliverables().size(),1);
        browser.setDocument({{"id","folder1"},{"name","Folder"},{"kind","folder"},{"mime_type","application/octet-stream"}},"drive:2","Details","drive");
        QVERIFY(browser.deliverables().isEmpty());
        browser.setDocument({{"attachments",QVariantList{report}}},"admin:1","Details","admin-users");
        QVERIFY(browser.deliverables().isEmpty());
    }
    void previewCollectionUsesVisibleFilesAndExcludesFoldersAndPrivateFields() {
        RecordListModel records;
        records.setRecords({QVariantMap{{"id","image1"},{"name","Hero.png"},{"mime_type","image/png"},{"secret","hidden"}},
            QVariantMap{{"id","file2"},{"name","Report.pdf"},{"mime_type","application/pdf"}},
            QVariantMap{{"id","folder1"},{"name","Hero sources"},{"kind","folder"},{"mime_type","application/octet-stream"}}});
        QCOMPARE(records.previewFiles().size(),2);
        records.setQuery("Hero"); const auto files=records.previewFiles(); QCOMPARE(files.size(),1);
        QCOMPARE(files.first().toMap().value("id").toString(),QString("image1"));
        QVERIFY(!files.first().toMap().contains("secret"));
    }
    void nestedSecretsAreNeverExposedAndTokenCountsRemainVisible() {
        DetailBrowser browser;
        browser.setDocument({{"password_hash","password-value"},{"Authorization","Bearer hidden"},{"api_key","api-value"},
            {"metadata",QVariantMap{{"Client-Secret","client-secret-value"},{"credentials",QVariantMap{{"user","hidden"}}},{"total_tokens",99},{"request",QVariantMap{{"refreshToken","refresh-value"},{"title","Visible request"}}}}}},
            "admin:1","Summary","admin-users");
        QCOMPARE(browser.rows()->rowCount(),1); browser.enter(detailRow(browser,"metadata")); QCOMPARE(browser.rows()->rowCount(),2);
        QVERIFY(!detailRow(browser,"total_tokens").isEmpty()); browser.enter(detailRow(browser,"request")); QCOMPARE(browser.rows()->rowCount(),1);
        const auto displayed=browser.rows()->data(browser.rows()->index(0,0),RecordListModel::Record).toMap();
        QCOMPARE(displayed.value("text").toString(),QString("Visible request"));
        RecordListModel records; records.setRecords({QVariantMap{{"id","row1"},{"title","Visible"},{"password","hidden"},{"metadata",QVariantMap{{"token","hidden"}}}}});
        const auto publicRecord=records.data(records.index(0),RecordListModel::Record).toMap();
        QVERIFY(!publicRecord.contains("password")); QVERIFY(!publicRecord.contains("metadata"));
        const auto rows=extractFeatureRecords(QJsonObject{{"data",QJsonObject{{"api_key","hidden"},{"total_tokens",10}}}});
        QCOMPARE(rows.size(),1); QCOMPARE(rows.first().toMap().value("id").toString(),QString("total_tokens"));
    }
    void nestedAdminReportsKeepOperatorNavigationSeparate() {
        DetailBrowser browser;
        browser.setDocument({{"subscriptions",QVariantList{QVariantMap{{"id","subscription1"},{"workspace_id","workspace1"},{"plan",QVariantMap{{"key","pro"},{"limits",QVariantMap{{"agents",9}}}}}}}},
            {"agent",QVariantMap{{"id","customer-agent"},{"display_name","Not implicitly a workspace member"}}}},"admin-summary","User summary","admin-users");
        QSignalSpy reference(&browser,&DetailBrowser::referenceRequested);
        browser.openReference(detailRow(browser,"agent")); QCOMPARE(reference.size(),0);
        browser.enter(detailRow(browser,"subscriptions")); browser.openReference(detailRow(browser,"0"));
        QCOMPARE(reference.size(),1); QCOMPARE(reference.first().first().toString(),QString("admin-subscriptions"));
        browser.enter(detailRow(browser,"0")); browser.openReference(detailRow(browser,"workspace_id"));
        QCOMPARE(reference.size(),2); QCOMPARE(reference.last().first().toString(),QString("admin-workspaces"));
        browser.enter(detailRow(browser,"plan")); browser.enter(detailRow(browser,"limits"));
        QCOMPARE(browser.rows()->rowCount(),1); QCOMPARE(browser.rows()->data(browser.rows()->index(0,0),RecordListModel::Record).toMap().value("text").toString(),QString("9"));
    }
    void collectionsRemainModelBackedAndReadable() {
        DetailBrowser browser; QAbstractItemModelTester modelCheck(browser.rows(),QAbstractItemModelTester::FailureReportingMode::QtTest);
        QVariantList items; for (int i=0;i<2000;++i) items.append(QVariantMap{{"id",QString("run%1").arg(i)},{"status","completed"},{"output",QVariantMap{{"summary","Actual output"}}}});
        browser.setDocument({{"items",items}},"runs","Execution history","tasks"); browser.enter(detailRow(browser,"items"));
        QCOMPARE(browser.rows()->rowCount(),2000); browser.enter(detailRow(browser,"1999")); browser.enter(detailRow(browser,"output"));
        QCOMPARE(browser.rows()->rowCount(),1);
        QCOMPARE(browser.rows()->data(browser.rows()->index(0,0),RecordListModel::Record).toMap().value("text").toString(),QString("Actual output"));
        browser.setDocument({{"items",QVariantList{}}},"other-account","Execution history","tasks"); QVERIFY(!browser.canGoBack());
    }
    void deferredSelectionWaitsForRowsAndLoadsOffPageUuid() {
        LocalApi remote; QVERIFY(remote.server.isListening());
        const QString target="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
        remote.handler=[&](QTcpSocket* socket,const QString& path) {
            if (path.startsWith("/api/admin/users?")) LocalApi::reply(socket,R"({"data":[{"id":"listed-user","full_name":"First page"}]})");
            else LocalApi::reply(socket,QJsonDocument(QJsonObject{{"data",QJsonObject{{"id",target},{"full_name","Requested user"}}}}).toJson(QJsonDocument::Compact));
        };
        QTemporaryDir directory; CacheStore cache(directory.path()); ApiClient api(remote.origin());
        PhoenixClient realtime; SessionController session(api,realtime); api.setSession("test-operator","operator",true);
        FeatureController controller(api,session,cache); controller.openRecord("admin-users",target);
        QTRY_COMPARE(controller.details().value("full_name").toString(),QString("Requested user"));
        QCOMPARE(controller.selectedId(),target); QVERIFY(remote.paths.contains("/api/admin/users/"+target));
    }
    void deferredSelectionCannotSurviveNavigationOrAccountChange() {
        LocalApi remote; QVERIFY(remote.server.isListening()); bool hold=true; QPointer<QTcpSocket> pending;
        remote.handler=[&](QTcpSocket* socket,const QString& path) {
            if (hold && path.startsWith("/api/admin/users?")) pending=socket;
            else LocalApi::reply(socket,R"({"data":[{"id":"same-id","name":"Unrelated record"}]})");
        };
        QTemporaryDir directory; CacheStore cache(directory.path()); ApiClient api(remote.origin());
        PhoenixClient realtime; SessionController session(api,realtime); api.setSession("test-alice","alice",true);
        FeatureController controller(api,session,cache); controller.openRecord("admin-users","same-id"); QTRY_VERIFY(pending);
        controller.navigate("admin-workspaces"); QTRY_VERIFY(!controller.busy()); QVERIFY(controller.selectedId().isEmpty());
        QTRY_VERIFY(!pending || pending->state()==QAbstractSocket::UnconnectedState);
        pending=nullptr; controller.openRecord("admin-users","same-id"); QTRY_VERIFY(pending);
        api.setSession("test-bob","bob",true); emit session.changed(); hold=false; controller.refresh();
        QTRY_VERIFY(!controller.busy()); QVERIFY(controller.selectedId().isEmpty());
    }
    void secondaryExecutionHistoryIsInspectableOnlineAndFromCache() {
        LocalApi remote; QVERIFY(remote.server.isListening());
        remote.handler=[](QTcpSocket* socket,const QString& path) {
            if (path.endsWith("/runs")) LocalApi::reply(socket,R"({"data":[{"id":"run1","status":"completed","output":{"tool_calls":[{"tool":"write_document","output":{"title":"Produced report"}}]}}]})");
            else if (path=="/api/tasks/task1") LocalApi::reply(socket,R"({"data":{"id":"task1","title":"Real task","comments":[]}})");
            else LocalApi::reply(socket,R"({"data":[{"id":"task1","title":"Real task"}],"meta":{"counts":{"completed":1}}})");
        };
        QTemporaryDir directory; CacheStore cache(directory.path()); ApiClient api(remote.origin());
        PhoenixClient realtime; SessionController session(api,realtime); api.setSession("test-alice","alice",false); api.setWorkspace("workspace-a");
        FeatureController controller(api,session,cache); controller.openRecord("tasks","task1"); QTRY_COMPARE(controller.details().value("title").toString(),QString("Real task"));
        controller.submit("runs",{}); QTRY_VERIFY(!controller.busy());
        auto* browser=qobject_cast<DetailBrowser*>(controller.detailView()); QVERIFY(browser);
        browser->enter(detailRow(*browser,"items")); browser->enter(detailRow(*browser,"0")); browser->enter(detailRow(*browser,"output")); browser->enter(detailRow(*browser,"tool_calls"));
        QCOMPARE(browser->rows()->rowCount(),1);
        controller.showRecordDetails(); QCOMPARE(controller.details().value("title").toString(),QString("Real task"));
        api.setOnline(false); const auto count=remote.paths.size(); controller.submit("runs",{}); QTRY_VERIFY(!controller.busy());
        QVERIFY(controller.offline()); QCOMPARE(controller.details().value("items").toList().size(),1); QCOMPARE(remote.paths.size(),count);
        controller.showOverview(); QVERIFY(controller.details().contains("meta"));
    }
};
QTEST_GUILESS_MAIN(FeatureTests)
#include "feature_tests.moc"
