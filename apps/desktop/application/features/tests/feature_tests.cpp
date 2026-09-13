#include <mokaid/features/feature_catalog.hpp>
#include <mokaid/features/feature_controller.hpp>
#include <mokaid/features/record_list_model.hpp>
#include <QAbstractItemModelTester>
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
                    bodies.append(QJsonDocument::fromJson(body.left(length)).object());
                    if (handler) handler(socket,path);
                });
            }
        });
    }
    QUrl origin() const { return QUrl(QString("http://127.0.0.1:%1").arg(server.serverPort())); }
    static void reply(QTcpSocket* socket,const QByteArray& json,int status=200) {
        socket->write("HTTP/1.1 "+QByteArray::number(status)+" Response\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: "+QByteArray::number(json.size())+"\r\n\r\n"+json);
        socket->disconnectFromHost();
    }
};

class FeatureTests final : public QObject {
    Q_OBJECT
private slots:
    void catalogSecurityBoundaries() {
        QCOMPARE(featureCatalog().size(),32);
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
