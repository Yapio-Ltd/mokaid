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

class FeatureTests final : public QObject {
    Q_OBJECT
private slots:
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
        QCOMPARE(featureCatalog().size(),31);
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
