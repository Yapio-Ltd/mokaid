#include <mokaid/features/feature_controller.hpp>
#include <QDir>
#include <QFile>
#include <QFontDatabase>
#include <QGuiApplication>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJSValue>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QtTest>
#include <memory>

using namespace mokaid::desktop;

// All records and transport in this target are isolated test fixtures. No live
// account, persisted user content, or production endpoint is used.
class NativePageApi final : public QObject {
public:
    QTcpServer server;
    QHash<QString,QJsonObject> responses;
    QStringList requests;
    NativePageApi() {
        server.listen(QHostAddress::LocalHost,0);
        connect(&server,&QTcpServer::newConnection,this,[this] {
            while (server.hasPendingConnections()) {
                auto* socket=server.nextPendingConnection();
                connect(socket,&QTcpSocket::disconnected,socket,&QObject::deleteLater);
                connect(socket,&QTcpSocket::readyRead,this,[this,socket] {
                    const auto request=socket->property("request").toByteArray()+socket->readAll();
                    socket->setProperty("request",request);
                    if (!request.contains("\r\n\r\n") || socket->property("handled").toBool()) return;
                    socket->setProperty("handled",true);
                    const auto path=QString::fromUtf8(request.split(' ').value(1)).section('?',0,0);
                    requests.append(path);
                    const auto body=QJsonDocument(responses.value(path,QJsonObject{{"data",QJsonArray{}}})).toJson(QJsonDocument::Compact);
                    socket->write("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: "+QByteArray::number(body.size())+"\r\n\r\n"+body);
                    socket->disconnectFromHost();
                });
            }
        });
    }
    QUrl origin() const { return QUrl(QString("http://127.0.0.1:%1").arg(server.serverPort())); }
    void collection(const QString& path,const QJsonArray& records) {
        responses.insert(path,{{"data",records}});
        for (const auto& row:records) {
            const auto object=row.toObject();
            if (!object.value("id").toString().isEmpty()) responses.insert(path+"/"+object.value("id").toString(),{{"data",object}});
        }
    }
};

class NativePageContext final : public QObject {
    Q_OBJECT
    Q_PROPERTY(int thumbnailRevision READ thumbnailRevision CONSTANT)
    Q_PROPERTY(QVariantMap selectedAgent MEMBER selectedAgent NOTIFY chatChanged)
    Q_PROPERTY(QVariantList conversations MEMBER conversations NOTIFY chatChanged)
    Q_PROPERTY(QVariantList messages MEMBER messages NOTIFY chatChanged)
    Q_PROPERTY(QString conversationId MEMBER conversationId NOTIFY chatChanged)
    Q_PROPERTY(QString draft MEMBER draft NOTIFY chatChanged)
    Q_PROPERTY(QString stream MEMBER stream NOTIFY chatChanged)
    Q_PROPERTY(QString error MEMBER error NOTIFY chatChanged)
    Q_PROPERTY(bool loading MEMBER loading NOTIFY chatChanged)
    Q_PROPERTY(bool sending MEMBER sending NOTIFY chatChanged)
public:
    QString testedAgent;
    QVariantMap selectedAgent;
    QVariantList conversations;
    QVariantList messages;
    QString conversationId, draft, stream, error;
    bool loading = false;
    bool sending = false;
    int thumbnailRevision() const { return 1; }
    Q_INVOKABLE QVariantMap describe(const QVariantMap&) const { return {{"kind","pdf"},{"label","PDF document"},{"extension","PDF"},{"sizeLabel","24 KB"}}; }
    Q_INVOKABLE QString thumbnailUrl(const QVariantMap&) const { return {}; }
    Q_INVOKABLE void openCollection(const QVariantList&,int) {}
    Q_INVOKABLE void openFile(const QVariantMap&) {}
    Q_INVOKABLE void selectAgent(const QString&) {}
    Q_INVOKABLE void beginForAgent(const QString& id) { testedAgent=id; }
    Q_INVOKABLE void closeChat() { selectedAgent.clear(); emit chatChanged(); }
    Q_INVOKABLE void selectConversation(const QString&) {}
    Q_INVOKABLE void newConversation() {}
    Q_INVOKABLE void send(const QVariantList&) {}
signals:
    void chatChanged();
};

class NativeSessionStub final : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool online READ online CONSTANT)
public:
    bool online() const { return true; }
};

struct NativePageFixture {
    NativePageApi remote;
    QTemporaryDir cacheDirectory;
    ApiClient api{remote.origin()};
    PhoenixClient realtime;
    SessionController session{api,realtime};
    CacheStore cache{cacheDirectory.path()};
    FeatureController features{api,session,cache};
    NativePageContext context;
    NativeSessionStub account;
    NativePageFixture() { api.setSession("test-only-session","fixture-user",false); api.setWorkspace("fixture-workspace"); }
};

class NativePageView final {
public:
    QTemporaryDir directory;
    QQmlEngine engine;
    QStringList warnings;
    std::unique_ptr<QObject> page;
    QQuickWindow window;
    QQuickItem* item{};
    QString failure;
    NativePageView(NativePageFixture& fixture,const QString& filename,const QByteArray& source={}) {
        for (const auto& name:QDir(QStringLiteral(MOKAID_NATIVE_QML_DIRECTORY)).entryList({"*.qml","*.js"},QDir::Files))
            QFile::copy(QStringLiteral(MOKAID_NATIVE_QML_DIRECTORY)+"/"+name,directory.path()+"/"+name);
        QFile qmldir(directory.path()+"/qmldir");
        if (!qmldir.open(QIODevice::WriteOnly)) { failure="Could not create the isolated QML module"; return; }
        qmldir.write("singleton Theme 1.0 Theme.qml\n"); qmldir.close();
        QObject::connect(&engine,&QQmlEngine::warnings,&engine,[this](const QList<QQmlError>& errors) { for (const auto& error:errors) warnings.append(error.toString()); });
        engine.rootContext()->setContextProperty("features",&fixture.features);
        engine.rootContext()->setContextProperty("session",&fixture.account);
        for (const auto* name:{"preview","office","missions"}) engine.rootContext()->setContextProperty(name,&fixture.context);
        QQmlComponent component(&engine);
        if (source.isEmpty()) component.loadUrl(QUrl::fromLocalFile(directory.path()+"/"+filename));
        else component.setData(source,QUrl::fromLocalFile(directory.path()+"/"+filename));
        page.reset(component.create()); failure=component.errorString();
        item=qobject_cast<QQuickItem*>(page.get());
        if (!item) return;
        window.setColor(QColor("#090b13")); item->setParentItem(window.contentItem()); resize(1320,810); window.show();
    }
    ~NativePageView() { if (item) item->setParentItem(nullptr); }
    void resize(int width,int height) { window.resize(width,height); if (item) item->setSize(QSizeF(width,height)); }
    QList<QQuickItem*> children() const {
        QList<QQuickItem*> result{item};
        for (qsizetype i=0;i<result.size();++i) result.append(result[i]->childItems());
        return result;
    }
    QQuickItem* find(const QString& name) const { for (auto* child:children()) if (child->objectName()==name) return child; return nullptr; }
    bool click(const QString& name) {
        // Prefer an on-screen, sized match. GridView reuseItems can leave
        // recycled delegates in the tree that still carry the objectName.
        QQuickItem* control=nullptr;
        for (auto* child:children()) {
            if (child->objectName()!=name || !child->isVisible()) continue;
            if (child->width()<=1 || child->height()<=1) continue;
            const auto origin=child->mapToScene(QPointF(0,0));
            if (origin.x()+child->width()<0 || origin.y()+child->height()<0) continue;
            if (origin.x()>window.width() || origin.y()>window.height()) continue;
            control=child;
            break;
        }
        if (!control) return false;
        QTest::mouseClick(&window,Qt::LeftButton,Qt::NoModifier,control->mapToScene(QPointF(control->width()/2,control->height()/2)).toPoint());
        return true;
    }
    bool capture(const QString& name) {
        const auto output=qEnvironmentVariable("MOKAID_NATIVE_CAPTURE_DIR");
        if (output.isEmpty()) return true;
        QDir().mkpath(output); return window.grabWindow().save(output+"/"+name+".png");
    }
    bool inside(const QString& name) const {
        const auto* child=find(name); if (!child || !child->isVisible()) return false;
        const auto point=child->mapToItem(item,QPointF());
        return point.x()>=-1 && point.y()>=-1 && point.x()+child->width()<=item->width()+1 && point.y()+child->height()<=item->height()+1;
    }
};

static QJsonArray agents() {
    return {
        QJsonObject{{"id","fixture-legal"},{"display_name","Fixture legal agent with a deliberately long display name"},{"role_title","Legal Specialist"},{"kind","ai"},{"status","active"},{"avatar_cdn_path","/assets3d/avatar_legal.859687268a64.glb"},{"skills",QJsonArray{"Contract analysis","Research","Compliance"}},{"missions_completed",18},{"performance_score",62},{"level",3},{"xp",38},{"xp_for_next_level",300},{"model_quality","smart"},{"autonomy_mode","balanced"},{"last_active_at","2026-09-17T10:30:00Z"},{"inserted_at","2026-09-01T10:00:00Z"},{"instructions","Reviews contracts and prepares clear reports. Follow workspace instructions and ask before taking consequential actions."}},
        QJsonObject{{"id","fixture-software"},{"display_name","Fixture software agent"},{"role_title","Software Engineer"},{"kind","ai"},{"status","idle"},{"avatar_cdn_path","/assets3d/avatar_developer.867211fc6b99.glb"},{"skills",QJsonArray{"Development","Code review"}},{"missions_completed",7},{"performance_score",43}},
        QJsonObject{{"id","fixture-research"},{"display_name","Fixture researcher"},{"role_title","Product Researcher"},{"kind","ai"},{"status","busy"},{"avatar_cdn_path","/assets3d/avatar_research.7c86fc428e9f.glb"},{"skills",QJsonArray{"Research","Analysis"}},{"current_task_id","fixture-task"},{"missions_completed",21},{"performance_score",71}},
        QJsonObject{{"id","fixture-media"},{"display_name","Fixture media & video"},{"role_title","Media Specialist"},{"kind","ai"},{"status","active"},{"avatar_cdn_path","/assets3d/avatar_design.1c0dba698d81.glb"},{"skills",QJsonArray{"Video","Design"}},{"missions_completed",5},{"performance_score",28}},
        QJsonObject{{"id","fixture-new"},{"display_name","Fixture new agent"},{"role_title","Trainee"},{"kind","ai"},{"status","training"},{"avatar_asset_id","custom-unresolved"},{"skills",QJsonArray{}},{"missions_completed",0},{"performance_score",QJsonValue::Null}}
    };
}

class NativePagesQmlTests final : public QObject {
    Q_OBJECT
    static QVariant property(QObject* object,const char* name) {
        const auto value=object->property(name);
        return value.metaType()==QMetaType::fromType<QJSValue>()?value.value<QJSValue>().toVariant():value;
    }
private slots:
    void workforcePortraitsFollowAssignedCharacters_data() {
        QTest::addColumn<QVariantMap>("agent");
        QTest::addColumn<QString>("portrait");
        const auto add=[](const char* label,const QString& path,const QString& character) {
            QTest::newRow(label)<<QVariantMap{{"display_name","Renamed agent"},{"kind","ai"},{"avatar_cdn_path",path}}
                <<(character.isEmpty()?QString():"qrc:/ui/portrait-"+character+".png");
        };
        add("deployed-legal","/assets3d/avatar_legal.12554af1b7e1.glb","legal");
        add("deployed-research","/assets3d/avatar_research.aee3f8496ec7.glb","research");
        add("deployed-developer","/assets3d/avatar_developer.d9c81b448040.glb","developer");
        add("deployed-male","/assets3d/avatar_male.342ae6ded162.glb","male");
        add("current-legal","/assets3d/avatar_legal.859687268a64.glb","legal");
        add("relative-design","assets3d/avatar_design.1c0dba698d81.glb","design");
        add("optimized-finance","assets/optimized/avatar_finance.1db634ff8a82.glb","finance");
        add("cdn-corporate","https://cdn.example.test/assets3d/avatar_corporate.b2951a24cd02.glb?v=2#model","corporate");
        add("byte","/assets3d/avatar_byte.05d5e3743ef8.glb","byte");
        add("nyx","/assets3d/avatar_nyx.5c7daa1a4ead.glb","nyx");
        add("moss","/assets3d/avatar_moss.96ccd7c01040.glb","moss");
        add("unversioned","/assets3d/avatar_research.glb","research");
        add("future-revision"," /assets3d/avatar_developer.0123456789ab.glb ","developer");
        add("default-avatar","","male");
        add("custom-location","/uploads/avatar_legal.859687268a64.glb","");
        add("unknown-character","/assets3d/avatar_custom.0123456789ab.glb","");
        QTest::newRow("unresolved-assignment")<<QVariantMap{{"kind","ai"},{"avatar_asset_id","custom-unresolved"}}<<QString();
        QTest::newRow("human")<<QVariantMap{{"kind","human_linked"},{"avatar_cdn_path","/assets3d/avatar_male.342ae6ded162.glb"}}<<QString();
        QTest::newRow("hybrid")<<QVariantMap{{"kind","hybrid"},{"avatar_cdn_path","/assets3d/avatar_legal.12554af1b7e1.glb"}}<<QString("qrc:/ui/portrait-legal.png");
    }
    void workforcePortraitsFollowAssignedCharacters() {
        QFETCH(QVariantMap,agent); QFETCH(QString,portrait);
        NativePageFixture fixture;
        NativePageView view(fixture,"WorkforcePortrait.qml"); QVERIFY2(view.item,qPrintable(view.failure));
        view.resize(72,72);
        QVERIFY(view.page->setProperty("agent",agent));
        QCOMPARE(view.page->property("portraitSource").toString(),portrait);
        if (!portrait.isEmpty()) {
            QQuickItem* image=nullptr;
            for (auto* child:view.children()) {
                if (child->property("source").toUrl()==QUrl(portrait) && child->property("status").isValid()) image=child;
            }
            QVERIFY(image);
            QTRY_COMPARE(image->property("status").toInt(),1); // Image.Ready, including the bundled PNG.
        }
        QVERIFY2(view.warnings.isEmpty(),qPrintable(view.warnings.join('\n')));
    }
    void officeCardsUseGeneratedPortraitsWithoutBorrowingCatalogFaces() {
        NativePageFixture fixture;
        NativePageView view(fixture,"AgentCard.qml"); QVERIFY2(view.item,qPrintable(view.failure));
        view.resize(240,120);
        const QVariantMap custom{{"kind","ai"},{"display_name","Alex Lane"},{"asset_type","custom:fixture"},{"avatar_asset_id","fixture-custom"}};
        QVERIFY(view.page->setProperty("agent",custom));
        QVERIFY(view.page->property("usesCustomPortrait").toBool());
        auto* portrait=view.find("officeCustomPortrait"); QVERIFY(portrait);
        QVERIFY(portrait->property("portraitSource").toString().isEmpty());
        QCOMPARE(portrait->property("initials").toString(),QString("AL"));
        QVERIFY(!view.find("officeCatalogPortrait"));
        auto withThumbnail=custom; withThumbnail.insert("avatar_thumbnail_url","https://mokaid.com/api/avatar-assets/fixture/token/thumbnail.png");
        QVERIFY(view.page->setProperty("agent",withThumbnail));
        QCOMPARE(portrait->property("portraitSource").toString(),withThumbnail.value("avatar_thumbnail_url").toString());
        QVERIFY(view.page->setProperty("agent",QVariantMap{{"kind","ai"},{"display_name","Catalog agent"},{"asset_type","legal"}}));
        QVERIFY(!view.page->property("usesCustomPortrait").toBool());
        auto* builtin=view.find("officeCatalogPortrait"); QVERIFY(builtin);
        QCOMPARE(builtin->property("kind").toString(),QString("legal"));
        QVERIFY(!view.find("officeCustomPortrait"));
    }
    void agentsUsePersistedDataAndKeepInteractionsAtMinimumSize() {
        NativePageFixture fixture; QVERIFY(fixture.remote.server.isListening());
        fixture.remote.collection("/api/agents",agents()); fixture.features.navigate("agents");
        QTRY_COMPARE(fixture.features.allRecords().size(),5); QTRY_VERIFY(!fixture.features.busy());
        NativePageView view(fixture,"AgentsPage.qml"); QVERIFY2(view.item,qPrintable(view.failure));
        QTRY_COMPARE(fixture.features.selectedId(),QString("fixture-legal")); QTest::qWait(120);
        QCOMPARE(property(view.page.get(),"summary").toMap().value("completed").toInt(),51);
        QCOMPARE(property(view.page.get(),"summary").toMap().value("rated").toInt(),4);
        QCOMPARE(property(view.page.get(),"summary").toMap().value("active").toInt(),3);
        QVERIFY(view.inside("agentRosterPanel")); QVERIFY(view.inside("agentInspector"));
        QVERIFY(view.capture("agents-wide"));
        QVERIFY(view.click("agentFilter_active")); QTRY_COMPARE(property(view.page.get(),"filteredAgents").toList().size(),3);
        QVERIFY(view.click("agentFilter_idle")); QTRY_COMPARE(property(view.page.get(),"filteredAgents").toList().size(),1);
        QVERIFY(view.click("agentRow_fixture-software")); QTRY_COMPARE(fixture.features.selectedId(),QString("fixture-software"));
        QVERIFY(view.click("testSelectedAgent")); QCOMPARE(fixture.context.testedAgent,QString("fixture-software"));
        QVERIFY(view.click("agentFilter_all")); QVERIFY(view.click("agentGridMode"));
        QTRY_VERIFY(view.page->property("gridMode").toBool()); QTest::qWait(120); QVERIFY(view.capture("agents-grid"));
        QTRY_VERIFY(view.inside("agentTile_fixture-legal"));
        QVERIFY(view.click("agentTile_fixture-legal")); QTRY_COMPARE(fixture.features.selectedId(),QString("fixture-legal"));
        QVERIFY(view.click("agentListMode"));
        for (int tab=0;tab<4;++tab) { QVERIFY(view.click("agentTab_"+QString::number(tab))); QCOMPARE(view.page->property("inspectorTab").toInt(),tab); }
        QVERIFY(view.click("agentTab_0"));
        fixture.features.search("no fixture matches this text"); QTRY_VERIFY(property(view.page.get(),"filteredAgents").toList().isEmpty());
        QCOMPARE(property(view.page.get(),"summary").toMap().value("total").toInt(),5);
        fixture.features.search(""); QTRY_COMPARE(property(view.page.get(),"filteredAgents").toList().size(),5);
        view.resize(750,580); QTest::qWait(60);
        QVERIFY(view.inside("agentRosterPanel")); QVERIFY(view.inside("agentInspector")); QVERIFY(view.capture("agents-minimum"));
        QVERIFY2(view.warnings.isEmpty(),qPrintable(view.warnings.join('\n')));
    }
    void agentKpisFollowAssignedTasks() {
        NativePageFixture fixture;
        fixture.remote.collection("/api/agents",agents());
        fixture.remote.collection("/api/tasks",{
            QJsonObject{{"id","legal-active"},{"assigned_agent_id","fixture-legal"},{"status","in_progress"},{"progress_percent",40}},
            QJsonObject{{"id","legal-second"},{"assigned_agent_id","fixture-legal"},{"status","waiting"},{"progress_percent",80}},
            QJsonObject{{"id","legal-canceled"},{"assigned_agent_id","fixture-legal"},{"status","canceled"},{"progress_percent",10}},
            QJsonObject{{"id","legal-today"},{"assigned_agent_id","fixture-legal"},{"status","completed"},{"progress_percent",100},{"completed_at","2026-09-22T10:00:00Z"}},
            QJsonObject{{"id","legal-earlier"},{"assigned_agent_id","fixture-legal"},{"status","completed"},{"progress_percent",100},{"completed_at","2026-09-20T08:00:00Z"}},
            QJsonObject{{"id","legal-old"},{"assigned_agent_id","fixture-legal"},{"status","completed"},{"progress_percent",100},{"completed_at","2026-08-01T08:00:00Z"}},
            QJsonObject{{"id","software-active"},{"assigned_agent_id","fixture-software"},{"status","in_progress"},{"progress_percent",90}},
            QJsonObject{{"id","orphan"},{"status","in_progress"},{"progress_percent",50}}
        });
        fixture.features.navigate("agents"); QTRY_COMPARE(fixture.features.allRecords().size(),5);
        NativePageView view(fixture,"AgentsPage.qml"); QVERIFY2(view.item,qPrintable(view.failure));
        view.page->setProperty("now",QDateTime::fromString("2026-09-22T12:00:00Z",Qt::ISODate).toMSecsSinceEpoch());
        QTRY_COMPARE(fixture.features.selectedId(),QString("fixture-legal"));
        QTRY_COMPARE(fixture.features.selectedAgentTasksState(),QString("ready"));
        const auto numbers=[](const QVariant& value) {
            QList<double> result; for (const auto& item:value.toList()) result.append(item.toDouble()); return result;
        };
        const auto same=[](const QList<double>& actual,std::initializer_list<double> expected) {
            if (actual.size()!=qsizetype(expected.size())) return false;
            int index=0; for (const auto value:expected) if (!qFuzzyCompare(actual[index++]+1.0,value+1.0)) return false; return true;
        };
        QCOMPARE(property(view.page.get(),"inspectorCurrentTask").toString(),QString("2"));
        QVERIFY(same(numbers(property(view.page.get(),"inspectorTaskBars")),{0.4,0.8}));
        QVERIFY(same(numbers(property(view.page.get(),"inspectorMissionBars")),{0,0,0,0,0,1,0,1}));
        QCOMPARE(property(view.page.get(),"inspectorMissionNote").toString(),QString("Last 8 days"));
        QVERIFY(qFuzzyCompare(property(view.page.get(),"inspectorPerformanceMeter").toDouble()+1.0,1.62));
        QVERIFY(view.click("agentRow_fixture-software"));
        QTRY_COMPARE(fixture.features.selectedId(),QString("fixture-software"));
        QTRY_COMPARE(fixture.features.selectedAgentTasksState(),QString("ready"));
        QTRY_COMPARE(property(view.page.get(),"inspectorCurrentTask").toString(),QString("1"));
        QVERIFY(same(numbers(property(view.page.get(),"inspectorTaskBars")),{0.9}));
        QVERIFY(numbers(property(view.page.get(),"inspectorMissionBars")).isEmpty());
        QVERIFY(view.click("agentRow_fixture-new"));
        QTRY_COMPARE(fixture.features.selectedId(),QString("fixture-new"));
        QTRY_COMPARE(property(view.page.get(),"inspectorCurrentTask").toString(),QString::fromUtf8("—"));
        QCOMPARE(property(view.page.get(),"inspectorPerformanceMeter").toDouble(),-1.0);
        QVERIFY(numbers(property(view.page.get(),"inspectorTaskBars")).isEmpty());
        QVERIFY2(view.warnings.isEmpty(),qPrintable(view.warnings.join('\n')));
    }
    void emptyWorkforceHasNoInventedMetricsOrSelection() {
        NativePageFixture fixture; fixture.remote.collection("/api/agents",{}); fixture.features.navigate("agents"); QTRY_VERIFY(!fixture.features.busy());
        NativePageView view(fixture,"AgentsPage.qml"); QVERIFY2(view.item,qPrintable(view.failure)); view.resize(750,580); QTest::qWait(50);
        QVERIFY(fixture.features.selectedId().isEmpty()); QVERIFY(!view.page->property("hasSelection").toBool());
        QCOMPARE(property(view.page.get(),"summary").toMap().value("total").toInt(),0); QVERIFY(property(view.page.get(),"summary").toMap().value("score").isNull());
        QVERIFY(view.capture("agents-empty")); QVERIFY2(view.warnings.isEmpty(),qPrintable(view.warnings.join('\n')));
    }
    void primaryNativePagesRender_data() {
        QTest::addColumn<QString>("pageId");
        for (const auto* page:{"tasks","projects","drive","calendar","mail","analytics","settings","agent-new","profile","members","integrations","billing"}) QTest::newRow(page)<<QString(page);
    }
    void primaryNativePagesRender() {
        QFETCH(QString,pageId);
        NativePageFixture fixture;
        QVERIFY2(fixture.remote.server.isListening(),"Loopback HTTP fixture must be available for populated page validation");
        fixture.remote.collection("/api/tasks",{
            QJsonObject{{"id","fixture-task"},{"title","Review the launch plan"},{"description","Review the source documents, check open questions and prepare the launch summary."},{"status","in_progress"},{"priority","high"},{"project_name","Autumn launch"},{"assigned_agent_name","Fixture researcher"},{"progress_percent",45},{"due_at","2026-09-24T10:00:00Z"}},
            QJsonObject{{"id","fixture-task-two"},{"title","Prepare the weekly report"},{"status","to_do"},{"priority","medium"},{"project_name","Operations"}},
            QJsonObject{{"id","fixture-task-three"},{"title","Publish the approved brief"},{"status","completed"},{"priority","low"},{"progress_percent",100}}
        });
        fixture.remote.collection("/api/projects",{QJsonObject{{"id","fixture-project"},{"name","Autumn launch"},{"description","Coordinate research, creative work and delivery."},{"status","active"},{"progress_percent",45},{"task_count",12},{"completed_task_count",5},{"members",QJsonArray{}},{"due_at","2026-10-01T10:00:00Z"}}});
        fixture.remote.collection("/api/drive",{QJsonObject{{"id","fixture-folder"},{"name","Launch documents"},{"kind","folder"},{"status","active"}},QJsonObject{{"id","fixture-file"},{"name","Launch brief.pdf"},{"kind","file"},{"status","active"},{"mime_type","application/pdf"},{"size_bytes",24000}}});
        fixture.remote.collection("/api/calendar/events",{QJsonObject{{"id","fixture-event"},{"title","Launch planning"},{"description","Review the upcoming launch."},{"start_at","2026-09-24T10:00:00Z"},{"end_at","2026-09-24T11:00:00Z"},{"kind","meeting"}}});
        fixture.remote.collection("/api/mail/messages",{QJsonObject{{"id","fixture-mail"},{"subject","Launch review: next steps"},{"from_name","Fixture teammate"},{"from_email","fixture@example.test"},{"received_at","2026-09-17T08:15:00Z"},{"snippet","The draft is ready for review."},{"body_text","The draft is ready for review. Please add your feedback before our planning meeting."},{"status","unread"}}});
        fixture.remote.responses.insert("/api/analytics/overview",{{"data",QJsonObject{{"overview",QJsonObject{{"total_tasks",12},{"completed_tasks",5},{"completion_rate",42},{"in_progress",4},{"overdue",1},{"active_agents",3},{"avg_task_hours",2.4}}},{"tasks_by_status",QJsonArray{QJsonObject{{"status","completed"},{"count",5}},QJsonObject{{"status","in_progress"},{"count",4}},QJsonObject{{"status","to_do"},{"count",3}}}},{"tasks_completed_daily",QJsonArray{QJsonObject{{"day","2026-09-16"},{"count",3}},QJsonObject{{"day","2026-09-17"},{"count",2}}}},{"top_agents",QJsonArray{QJsonObject{{"display_name","Fixture researcher"},{"role_title","Researcher"},{"tasks_done",5}}}}}}});
        fixture.remote.responses.insert("/api/workspaces/fixture-workspace",{{"data",QJsonObject{{"id","fixture-workspace"},{"name","Fixture workspace"},{"description","A test workspace for native presentation checks."},{"industry","Technology"},{"timezone","Asia/Jerusalem"},{"language","en"},{"date_format","MMM d, yyyy"},{"time_format","24h"}}}});
        fixture.remote.responses.insert("/api/me",{{"data",QJsonObject{{"user",QJsonObject{{"id","fixture-user"},{"full_name","Fixture teammate"},{"email","fixture@example.test"},{"locale","en"},{"timezone","Asia/Jerusalem"}}}}}});
        fixture.remote.collection("/api/members",{QJsonObject{{"id","fixture-member"},{"full_name","Fixture teammate"},{"email","fixture@example.test"},{"status","active"},{"role_name","Member"}}});
        fixture.remote.responses.insert("/api/mcp",{{"data",QJsonObject{{"servers",QJsonArray{QJsonObject{{"key","fixture-server"},{"name","Fixture integration"},{"description","A test tool connection."},{"category","Productivity"}}}}}}});
        fixture.remote.responses.insert("/api/billing/overview",{{"data",QJsonObject{{"plan",QJsonObject{{"name","Fixture plan"}}},{"credits",QJsonObject{{"balance",120}}},{"subscription",QJsonObject{{"status","active"},{"billing_cycle","monthly"}}}}}});
        fixture.remote.responses.insert("/api/agents/catalog",{{"data",QJsonObject{{"archetypes",QJsonArray{QJsonObject{{"key","researcher"},{"name","Researcher"},{"description","Investigates questions and produces clear source-backed reports."}},QJsonObject{{"key","developer"},{"name","Developer"},{"description","Builds software and helps maintain your code."}}}}}}});
        fixture.features.navigate(pageId); QTRY_VERIFY(!fixture.features.busy()); QVERIFY2(fixture.features.error().isEmpty(),qPrintable(fixture.features.error()));
        NativePageView view(fixture,"FeaturePage.qml"); QVERIFY2(view.item,qPrintable(view.failure)); QTest::qWait(70); QVERIFY(view.capture(pageId+"-wide"));
        view.resize(750,580); QTest::qWait(40); QVERIFY(view.capture(pageId+"-minimum"));
        if (!fixture.features.allRecords().isEmpty() && pageId!="analytics" && pageId!="settings") {
            fixture.features.select(featureRecordId(fixture.features.allRecords().first().toMap())); QTest::qWait(60);
            QVERIFY(view.capture(pageId+"-inspector-minimum"));
        }
        QVERIFY2(view.warnings.isEmpty(),qPrintable(view.warnings.join('\n')));
    }
    void taskBoardDefaultsSurviveNavigationAndAllStatusesRemainVisible() {
        NativePageFixture fixture;
        QJsonArray tasks;
        for (const auto* status:{"to_do","in_progress","in_review","waiting","blocked","completed","canceled","overdue"})
            tasks.append(QJsonObject{{"id",QString("task-")+status},{"title",QString("Fixture ")+status},{"status",status},{"priority","medium"}});
        fixture.remote.collection("/api/tasks",tasks);
        fixture.features.navigate("mail"); QTRY_VERIFY(!fixture.features.busy());
        NativePageView view(fixture,"FeaturePage.qml"); QVERIFY2(view.item,qPrintable(view.failure));
        QCOMPARE(view.page->property("viewMode").toString(),QString("list"));
        fixture.features.navigate("tasks"); QTRY_VERIFY(!fixture.features.busy());
        QTRY_COMPARE(view.page->property("viewMode").toString(),QString("board"));
        QCOMPARE(fixture.features.visibleRecords().size(),8);
        for (const auto& lane:QList<QPair<QString,int>>{{"todo",1},{"doing",1},{"review",4},{"done",2}}) {
            QTRY_VERIFY(view.find("taskLaneList_"+lane.first));
            QTRY_COMPARE(view.find("taskLaneList_"+lane.first)->property("count").toInt(),lane.second);
        }
        QTRY_VERIFY(view.find("featureCollection"));
        QVERIFY(view.inside("featureCollection"));
        QVERIFY(view.click("featureListMode"));
        QCOMPARE(view.page->property("viewMode").toString(),QString("list"));
        QVERIFY(view.click("taskBoardMode"));
        QCOMPARE(view.page->property("viewMode").toString(),QString("board"));
        fixture.features.navigate("projects"); QTRY_VERIFY(!fixture.features.busy());
        QTRY_COMPARE(view.page->property("viewMode").toString(),QString("grid"));
        fixture.features.navigate("tasks"); QTRY_VERIFY(!fixture.features.busy());
        QTRY_COMPARE(view.page->property("viewMode").toString(),QString("board"));
        view.resize(750,580); QTest::qWait(60);
        QVERIFY(view.inside("featureCollection"));
        QVERIFY(view.capture("tasks-all-statuses-minimum"));
        QVERIFY(view.click("taskCard_task-to_do"));
        QTRY_COMPARE(fixture.features.selectedId(),QString("task-to_do"));
        QTRY_VERIFY(!fixture.features.busy());
        QVERIFY(view.inside("featureInspector"));
        QVERIFY(view.inside("taskInspectorClose"));
        QSignalSpy actionRequests(view.page.get(),SIGNAL(actionRequested(QVariant)));
        QVERIFY(actionRequests.isValid());
        QVERIFY(view.click("taskQuick_comment"));
        QTRY_COMPARE(actionRequests.size(),1);
        QCOMPARE(actionRequests.takeFirst().first().toMap().value("id").toString(),QString("comment"));
        QVERIFY(view.capture("tasks-selected-minimum"));
        QVERIFY(view.click("taskInspectorClose"));
        QTRY_VERIFY(fixture.features.selectedId().isEmpty());
        QVERIFY(view.inside("featureCollection"));
        fixture.features.search("no matching task");
        QTRY_VERIFY(fixture.features.visibleRecords().isEmpty());
        QCOMPARE(fixture.features.allRecords().size(),8);
        fixture.features.search(""); QTRY_COMPARE(fixture.features.visibleRecords().size(),8);
        QVERIFY2(view.warnings.isEmpty(),qPrintable(view.warnings.join('\n')));
    }
    void agentCreationHasExplicitSelectionAndResponsiveNextStep() {
        NativePageFixture fixture; QVERIFY(fixture.remote.server.isListening());
        fixture.remote.responses.insert("/api/agents/catalog",{{"data",QJsonObject{{"archetypes",QJsonArray{
            QJsonObject{{"key","researcher"},{"name","Researcher"},{"description","Find answers and prepare a clear brief."},{"role_title","Research Specialist"},{"department","Research"},{"skills",QJsonArray{"research","analysis"}}},
            QJsonObject{{"key","developer"},{"name","Developer"},{"description","Build and maintain useful software."},{"skills",QJsonArray{"coding","debugging"}}}
        }}}}});
        fixture.features.navigate("agent-new"); QTRY_VERIFY(!fixture.features.busy());
        QTRY_COMPARE(fixture.features.allRecords().size(),2);
        NativePageView view(fixture,"AgentCreationPage.qml"); QVERIFY2(view.item,qPrintable(view.failure));
        QTest::qWait(60); // Allow the first GridView/layout polish before pointer input.
        QTRY_VERIFY(view.find("agentCreationContinue"));
        QVERIFY(!view.find("agentCreationContinue")->isEnabled());
        QVERIFY(view.click("roleCard_researcher"));
        QTRY_COMPARE(fixture.features.selectedRecord().value("key").toString(),QString("researcher"));
        QTRY_VERIFY(view.find("agentCreationContinue")->isEnabled());
        QSignalSpy next(view.page.get(),SIGNAL(actionRequested(QVariant))); QVERIFY(next.isValid());
        QVERIFY(view.click("agentCreationContinue"));
        QTRY_COMPARE(next.size(),1);
        const auto action=next.takeFirst().first().toMap();
        QCOMPARE(action.value("id").toString(),QString("create"));
        QCOMPARE(action.value("specialization").toMap().value("key").toString(),QString("researcher"));
        QVERIFY(view.capture("agent-creation-selected-wide"));
        view.resize(750,580); QTest::qWait(60);
        QVERIFY(view.inside("agentCreationContinue"));
        QVERIFY(view.click("roleCard_developer"));
        QTRY_COMPARE(fixture.features.selectedRecord().value("key").toString(),QString("developer"));
        QVERIFY(view.capture("agent-creation-selected-minimum"));
        auto* search=view.find("agentCreationSearch"); QVERIFY(search); search->forceActiveFocus();
        for (const auto character:QByteArray("no matching role")) QTest::keyClick(&view.window,character);
        QTRY_VERIFY(property(view.page.get(),"roles").toList().isEmpty());
        // A search changes the catalog view, not the user's chosen specialty.
        QVERIFY(view.find("agentCreationContinue")->isEnabled());
        QVERIFY(view.capture("agent-creation-search-empty"));
        QVERIFY2(view.warnings.isEmpty(),qPrintable(view.warnings.join('\n')));
    }
    void officeChatOffersRentSaleAndPerformance() {
        NativePageFixture fixture;
        fixture.context.selectedAgent=QVariantMap{{"id","fixture-legal"},{"display_name","Devio"},{"role_title","Software Engineer"},{"kind","ai"}};
        NativePageView view(fixture,"ChatPanel.qml");
        QVERIFY2(view.item,qPrintable(view.failure));
        QVERIFY(view.inside("rentOutAgent"));
        QVERIFY(view.inside("sellAgent"));
        QVERIFY(view.inside("agentPerformance"));
        QVERIFY(view.click("rentOutAgent"));
        QTRY_COMPARE(fixture.features.currentPage(),QString("marketplace"));
        QCOMPARE(fixture.features.pendingOfferAgentId(),QString("fixture-legal"));
        QCOMPARE(fixture.features.pendingOfferMode(),QString("rent"));
        fixture.features.navigate("office");
        QTRY_COMPARE(fixture.features.currentPage(),QString("office"));
        QVERIFY(fixture.features.pendingOfferAgentId().isEmpty());
        QVERIFY(view.click("sellAgent"));
        QTRY_COMPARE(fixture.features.pendingOfferMode(),QString("sale"));
        QVERIFY(view.click("agentPerformance"));
        QTRY_COMPARE(fixture.features.currentPage(),QString("agent-performance"));
        QVERIFY2(view.warnings.isEmpty(),qPrintable(view.warnings.join('\n')));
    }
    void agentPerformanceUsesAssignedTaskHistory() {
        NativePageFixture fixture;
        fixture.remote.collection("/api/agents",agents());
        fixture.remote.collection("/api/tasks",{
            QJsonObject{{"id","legal-active"},{"title","Review the clause"},{"assigned_agent_id","fixture-legal"},{"status","in_progress"},{"priority","high"},{"progress_percent",40},{"inserted_at","2026-09-21T09:00:00Z"}},
            QJsonObject{{"id","legal-second"},{"title","Wait for signature"},{"assigned_agent_id","fixture-legal"},{"status","waiting"},{"priority","low"},{"progress_percent",80}},
            QJsonObject{{"id","legal-canceled"},{"title","Dropped request"},{"assigned_agent_id","fixture-legal"},{"status","canceled"},{"progress_percent",10}},
            QJsonObject{{"id","legal-today"},{"title","File the brief"},{"assigned_agent_id","fixture-legal"},{"status","completed"},{"progress_percent",100},{"completed_at","2026-09-22T10:00:00Z"},{"latest_run",QJsonObject{{"status","completed"},{"credits_charged",4},{"token_usage",QJsonObject{{"total_tokens",1200}}},{"completed_at","2026-09-22T10:05:00Z"}}},{"comments",QJsonArray{QJsonObject{{"body","Ready to send"},{"author_name","Devio"},{"inserted_at","2026-09-22T10:06:00Z"}}}}},
            QJsonObject{{"id","legal-earlier"},{"title","Earlier brief"},{"assigned_agent_id","fixture-legal"},{"status","completed"},{"progress_percent",100},{"completed_at","2026-09-20T08:00:00Z"}},
            QJsonObject{{"id","legal-old"},{"title","Old brief"},{"assigned_agent_id","fixture-legal"},{"status","completed"},{"progress_percent",100},{"completed_at","2026-08-01T08:00:00Z"}},
            QJsonObject{{"id","software-active"},{"assigned_agent_id","fixture-software"},{"status","in_progress"},{"progress_percent",90}}
        });
        fixture.features.openRecord("agent-performance","fixture-legal");
        QTRY_COMPARE(fixture.features.selectedId(),QString("fixture-legal"));
        QTRY_COMPARE(fixture.features.selectedAgentTasksState(),QString("ready"));
        NativePageView view(fixture,"AgentPerformancePage.qml");
        QVERIFY2(view.item,qPrintable(view.failure));
        view.page->setProperty("now",QDateTime::fromString("2026-09-22T12:00:00Z",Qt::ISODate).toMSecsSinceEpoch());
        QCOMPARE(property(view.page.get(),"performanceLabel").toString(),QString("62"));
        QVERIFY(qFuzzyCompare(property(view.page.get(),"performanceMeter").toDouble()+1.0,1.62));
        QCOMPARE(property(view.page.get(),"openTaskCount").toInt(),2);
        QCOMPARE(property(view.page.get(),"completedTaskCount").toInt(),3);
        QCOMPARE(property(view.page.get(),"taskCompletionPercent").toInt(),50);
        const auto totals=property(view.page.get(),"latestRunTotals").toMap();
        QCOMPARE(totals.value("credits").toInt(),4);
        QCOMPARE(totals.value("tokens").toInt(),1200);
        const auto progress=property(view.page.get(),"progressHistogram").toList();
        QCOMPARE(progress.size(),4);
        QCOMPARE(progress.at(0).toInt(),1);
        QCOMPARE(progress.at(1).toInt(),1);
        QCOMPARE(progress.at(2).toInt(),0);
        QCOMPARE(progress.at(3).toInt(),4);
        const auto completions=property(view.page.get(),"completionSeries").toList();
        QCOMPARE(completions.size(),14);
        QCOMPARE(completions.at(11).toInt(),1);
        QCOMPARE(completions.at(13).toInt(),1);
        const auto log=property(view.page.get(),"activityLog").toList();
        QVERIFY(!log.isEmpty());
        QCOMPARE(log.first().toMap().value("title").toString(),QString("Devio"));
        QCOMPARE(log.first().toMap().value("detail").toString(),QString("Ready to send"));
        QVERIFY(view.inside("performanceBack"));
        QVERIFY(view.find("performanceStatusChart"));
        QVERIFY(view.find("performanceLog"));
        QVERIFY(view.click("performanceBack"));
        QTRY_COMPARE(fixture.features.currentPage(),QString("office"));
        QVERIFY2(view.warnings.isEmpty(),qPrintable(view.warnings.join('\n')));
    }
    void marketplaceOfferOpensRentForThatAgent() {
        NativePageFixture fixture;
        fixture.remote.responses.insert("/api/marketplace/listings",{{"data",QJsonArray{}}});
        fixture.remote.responses.insert("/api/marketplace/mine",{{"data",QJsonArray{QJsonObject{
            {"agent",QJsonObject{{"id","fixture-legal"},{"display_name","Fixture legal"},{"kind","ai"},{"role_title","Legal Specialist"},{"status","active"}}},
            {"eligible",true},{"level",12},{"knowledge_item_count",3}
        }}},{"meta",QJsonObject{{"min_level",10},{"fee_percent",15},{"connect_ready",true}}}});
        fixture.features.openMarketplaceOffer("fixture-legal","rent");
        QTRY_COMPARE(fixture.features.currentPage(),QString("marketplace"));
        QCOMPARE(fixture.features.pendingOfferAgentId(),QString("fixture-legal"));
        NativePageView view(fixture,"MarketplacePage.qml");
        QVERIFY2(view.item,qPrintable(view.failure));
        QTRY_COMPARE(view.page->property("screen").toString(),QString("publish"));
        QCOMPARE(view.page->property("publishMode").toString(),QString("rent"));
        QCOMPARE(view.page->property("publishAgentId").toString(),QString("fixture-legal"));
        QVERIFY(fixture.features.pendingOfferAgentId().isEmpty());
        QVERIFY2(view.warnings.isEmpty(),qPrintable(view.warnings.join('\n')));
    }
};
int main(int argc,char**argv) {
    qputenv("QT_QPA_PLATFORM","offscreen");
    QQuickWindow::setGraphicsApi(QSGRendererInterface::Software); QQuickStyle::setStyle("Basic");
    QGuiApplication app(argc,argv);
    QFontDatabase::addApplicationFont(QStringLiteral(MOKAID_NATIVE_QML_DIRECTORY)+"/../assets/fonts/Manrope.ttf");
    NativePagesQmlTests tests; return QTest::qExec(&tests,argc,argv);
}
#include "native_pages_qml_tests.moc"
