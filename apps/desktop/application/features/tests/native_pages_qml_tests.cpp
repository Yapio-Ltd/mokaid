#include <mokaid/features/feature_controller.hpp>
#include <QDir>
#include <QDateTime>
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
#include <QSettings>
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
    QStringList methods;
    QList<QJsonObject> bodies;
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
                    const auto headersEnd=request.indexOf("\r\n\r\n");
                    qsizetype length=0;
                    for (const auto& line:request.left(headersEnd).split('\n'))
                        if (line.toLower().startsWith("content-length:")) length=line.mid(15).trimmed().toLongLong();
                    const auto requestBody=request.mid(headersEnd+4);
                    if (requestBody.size()<length) return;
                    socket->setProperty("handled",true);
                    const auto path=QString::fromUtf8(request.split(' ').value(1)).section('?',0,0);
                    requests.append(path);
                    methods.append(QString::fromUtf8(request.split(' ').value(0)));
                    bodies.append(QJsonDocument::fromJson(requestBody.left(length)).object());
                    const auto body=QJsonDocument(responses.value(methods.last()+" "+path,responses.value(path,QJsonObject{{"data",QJsonArray{}}}))).toJson(QJsonDocument::Compact);
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
    Q_PROPERTY(QString workspaceId READ workspaceId CONSTANT)
public:
    bool online() const { return true; }
    QString workspaceId() const { return QStringLiteral("fixture-workspace"); }
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

static QJsonArray marketplaceListings() {
    const auto listing=[](const QString& id,const QString& name,const QString& role,const QString& department,const QString& avatar,const QString& mode,int price,const QJsonArray& skills) {
        return QJsonObject{{"id",id},{"workspace_id","fixture-seller"},{"title",name},{"description","An experienced AI specialist ready to help your team with clear, thoughtful work."},
            {"mode",mode},{"rent_billing",mode=="rent"?QJsonValue("subscription"):QJsonValue::Null},{"price_cents",price},{"currency","usd"},{"status","active"},{"agent_level",12},{"knowledge_item_count",8},
            {"inserted_at","2026-09-25T09:00:00Z"},{"agent",QJsonObject{{"id","source-"+id},{"kind","ai"},{"display_name",name},{"role_title",role},{"department",department},{"level",12},
                {"avatar_cdn_path","/assets3d/avatar_"+avatar+".0123456789ab.glb"},{"skills",skills}}}};
    };
    return {
        listing("listing-legal","Taya","Legal Specialist","legal","legal","rent",2900,{"Contract review","Compliance"}),
        listing("listing-software","Devio","Software Engineer","development","developer","sale",9900,{"Development","Code review"}),
        listing("listing-research","Sira","Research Assistant","research","research","rent",1900,{"Research","Data analysis"}),
        listing("listing-design","Luna","Brand Designer","design","design","sale",14900,{"Design","Brand strategy"})
    };
}

class NativePagesQmlTests final : public QObject {
    Q_OBJECT
    static QVariant property(QObject* object,const char* name) {
        const auto value=object->property(name);
        return value.metaType()==QMetaType::fromType<QJSValue>()?value.value<QJSValue>().toVariant():value;
    }
private slots:
    void googleCalendarConnectsFromItsPageAndServicesFitMinimumWindow() {
        NativePageFixture fixture; QVERIFY(fixture.remote.server.isListening());
        fixture.remote.responses.insert("POST /api/integrations/google/desktop/start",{{"data",QJsonObject{{"flow_id","google-flow"},{"authorize_url","https://accounts.google.com/o/oauth2/v2/auth?state=test-only"}}}});
        fixture.remote.responses.insert("GET /api/integrations/google/desktop/google-flow",{{"data",QJsonObject{{"status","pending"}}}});
        fixture.remote.responses.insert("DELETE /api/integrations/google/desktop/google-flow",{{"data",QJsonObject{{"status","failed"},{"error","authorization_cancelled"}}}});
        fixture.remote.responses.insert("/api/integrations",{{"data",QJsonObject{{"connections",QJsonArray{}}}}});
        fixture.features.navigate("calendar"); QTRY_VERIFY(!fixture.features.busy());
        auto& google=*qobject_cast<GoogleConnectionsController*>(fixture.features.googleConnections()); QTRY_VERIFY(!google.refreshing());
        NativePageView view(fixture,"FeaturePage.qml"); QVERIFY2(view.item,qPrintable(view.failure)); view.resize(760,620);
        const auto find=[&view](const QString& name) -> QQuickItem* {
            QList<QQuickItem*> children{view.window.contentItem()};
            for(qsizetype i=0;i<children.size();++i) { if(children[i]->objectName()==name) return children[i]; children.append(children[i]->childItems()); }
            return nullptr;
        };
        const auto click=[&view,&find](const QString& name) -> bool {
            auto* item=find(name); if(!item || !item->isVisible() || item->width()<1 || item->height()<1) return false;
            QTest::mouseClick(&view.window,Qt::LeftButton,Qt::NoModifier,item->mapToScene(QPointF(item->width()/2,item->height()/2)).toPoint()); return true;
        };
        QSignalSpy browser(&google,&GoogleConnectionsController::requestExternal), connected(&google,&GoogleConnectionsController::connected);
        QTRY_VERIFY(view.inside("googleServiceConnectButton"));
        QVERIFY(view.capture("google-calendar-page-760"));
        QVERIFY(view.click("googleServiceConnectButton")); QTRY_COMPARE(browser.count(),1); QVERIFY(google.pending());
        const auto request=fixture.remote.requests.indexOf("/api/integrations/google/desktop/start");
        QCOMPARE(fixture.remote.bodies.at(request).value("provider_key").toString(),QString("google_calendar"));
        QTRY_VERIFY(find("googleSignInHelp")); QVERIFY(find("googleSignInHelp")->isVisible());
        QVERIFY(find("googleSignInHelp")->property("text").toString().contains("testing"));
        QCOMPARE(connected.count(),0); QVERIFY(view.capture("google-calendar-waiting-760"));
        QVERIFY(click("googleConnectionClose")); QTRY_VERIFY(!google.pending()); QCOMPARE(connected.count(),0);
        QTRY_VERIFY(find("googleShowAllServices")->isVisible()); QVERIFY(click("googleShowAllServices"));
        QTRY_VERIFY(find("googleConnect_google_meet"));
        for(const auto* key:{"gmail","google_calendar","google_drive","google_docs","google_sheets","google_meet"}) {
            auto* button=find("googleConnect_"+QString(key)); QVERIFY(button); QVERIFY(button->isEnabled());
        }
        const auto* close=find("googleConnectionClose"); QVERIFY(close); QVERIFY(close->mapToScene(QPointF()).y()+close->height()<=620);
        QVERIFY(view.capture("google-services-760"));
        auto* scroll=find("googleServicesScroll"); QVERIFY(scroll);
        auto* flickable=scroll->property("contentItem").value<QObject*>(); QVERIFY(flickable);
        flickable->setProperty("contentY",flickable->property("contentHeight").toDouble()-scroll->height());
        QTRY_VERIFY(find("googleConnect_google_meet")->mapToScene(QPointF()).y()+find("googleConnect_google_meet")->height()<=close->mapToScene(QPointF()).y());
        QVERIFY(view.capture("google-services-bottom-760"));
        flickable->setProperty("contentY",0); QTest::qWait(20);
        QVERIFY(click("googleConnect_google_drive")); QTRY_COMPARE(browser.count(),2); QCOMPARE(google.providerKey(),QString("google_drive"));
        fixture.remote.responses.insert("GET /api/integrations/google/desktop/google-flow",{{"data",QJsonObject{{"status","connected"},{"provider_key","google_drive"},{"connection_id","saved-drive"},{"connected_account","alice@example.test"},{"mcp_status","different_account"},{"mcp_connected_account","other@example.test"}}}});
        fixture.remote.responses.insert("/api/integrations",{{"data",QJsonObject{{"connections",QJsonArray{QJsonObject{{"id","saved-drive"},{"provider_key","google_drive"},{"provider_name","Google Drive"},{"status","connected"},{"connected_account","alice@example.test"}}}}}}});
        QVERIFY(click("googleCheckConnection")); QTRY_COMPARE(connected.count(),1); QVERIFY(!google.pending());
        QTRY_COMPARE(google.connections().size(),1); QVERIFY(google.needsAttention()); QVERIFY(google.message().contains("other@example.test"));
        QVERIFY(view.capture("google-drive-account-warning-760"));
        fixture.api.setOnline(false); QTRY_VERIFY(!find("googleConnect_google_drive")->isEnabled());
        fixture.api.setWorkspace("other-workspace"); google.setActive(true); QTRY_VERIFY(!find("googleConnectionClose") || !find("googleConnectionClose")->isVisible());
        QVERIFY2(view.warnings.isEmpty(),qPrintable(view.warnings.join('\n')));
    }
    void mailCenterReaderComposerAndAttachmentsFitWideAndCompact() {
        NativePageFixture fixture; QVERIFY(fixture.remote.server.isListening());
        const QJsonArray attachments{QJsonObject{{"id","fixture-part"},{"filename","Campaign overview.pdf"},{"mime_type","application/pdf"},{"size",21800}}};
        const QJsonObject first{{"id","fixture-message"},{"mail_account_id","fixture-account"},{"from_name","Olivia Martin"},{"from_email","olivia@example.test"},{"to_emails",QJsonArray{"alex@example.test"}},{"subject","A fresh start for the autumn campaign"},{"snippet","Hi Alex, here is the updated campaign overview for our next launch."},{"body_html","<h2>A little inspiration for the week ahead</h2><p>Hi Alex,</p><p>Here is the updated <b>campaign overview</b> for our next launch. We have brought the key ideas together so everyone can review them before Thursday.</p><ul><li>New product photography</li><li>A clearer story for our customers</li><li>Final review on Thursday</li></ul><p>Let me know what you think, and feel free to share any questions.</p><p>Thanks,<br>Olivia</p>"},{"body_text","Campaign overview"},{"received_at","2026-09-27T11:24:00Z"},{"is_read",false},{"is_starred",true},{"has_attachments",true},{"attachments",attachments},{"ai_category","marketing"}};
        QJsonArray messages{first};
        for(int i=0;i<8;++i) messages.append(QJsonObject{{"id","fixture-message-"+QString::number(i)},{"mail_account_id","fixture-account"},{"from_name",QStringList{"Morgan Lee","Accounts Team","Jamie Brooks","Product Weekly"}.at(i%4)},{"from_email","team@example.test"},{"subject",QStringList{"Your monthly statement is ready","Thursday project review","A few notes from our planning session","Your weekly product digest"}.at(i%4)},{"snippet","An update from your team. Open this message to read the full details."},{"received_at","2026-09-26T09:20:00Z"},{"is_read",i%2==0},{"is_starred",false},{"ai_category",QStringList{"finance","notification","work","marketing"}.at(i%4)}});
        fixture.remote.collection("/api/mail/messages",messages);
        fixture.remote.responses.insert("/api/mail/accounts",{{"data",QJsonArray{QJsonObject{{"id","fixture-account"},{"email_address","alex@example.test"},{"provider","gmail"},{"status","active"}}}},{"meta",QJsonObject{{"can_send",true},{"can_manage",true}}}});
        fixture.remote.responses.insert("/api/mail/folders",{{"data",QJsonArray{QJsonObject{{"key","inbox"},{"count",9},{"unread_count",5}},QJsonObject{{"key","starred"},{"count",1}},QJsonObject{{"key","sent"},{"count",14}}}},{"meta",QJsonObject{{"labels",QJsonArray{QJsonObject{{"name","Projects"},{"count",12}},QJsonObject{{"name","Finance"},{"count",4}},QJsonObject{{"name","Marketing"},{"count",7}}}}}}});
        fixture.features.navigate("mail");
        auto& center=*qobject_cast<MailCenterController*>(fixture.features.mailCenter());
        QTRY_COMPARE(center.messages().size(),9); QTRY_VERIFY(!center.detailLoading()); QTRY_VERIFY(center.canSend());
        NativePageView view(fixture,"FeaturePage.qml"); QVERIFY2(view.item,qPrintable(view.failure));
        QTRY_VERIFY(view.find("mailMessageBody")); QTest::qWait(80);
        QCOMPARE(view.find("mailAccountSelector")->property("displayText").toString(),QString("All mailboxes"));
        QVERIFY(view.inside("mailFolders")); QVERIFY(view.inside("mailMessagesPanel")); QVERIFY(view.inside("mailReaderPanel"));
        QVERIFY(view.capture("mail-center-wide"));
        QCOMPARE(fixture.remote.methods.count("PATCH"),0); // Opening or refreshing never marks real mail read.
        QSignalSpy opened(&fixture.features,&FeatureController::openDelivery);
        QVERIFY(view.click("mailViewAttachment_fixture-part")); QCOMPARE(opened.count(),1);
        QCOMPARE(opened.first().first().toMap().value("mail_message_id").toString(),QString("fixture-message"));
        QVERIFY(view.click("mailReplyButton")); QTRY_VERIFY(center.composing());
        QCOMPARE(center.draft().value("to").toString(),QString("olivia@example.test"));
        center.setDraft("body_text","Thank you, Olivia. I will review the campaign overview this afternoon.");
        QVERIFY(center.hasDraft()); QVERIFY(view.inside("mailSendButton"));
        QVERIFY(view.capture("mail-reply-wide"));
        QVERIFY(view.click("mailCloseComposer")); QVERIFY(!center.composing()); QVERIFY(center.hasDraft());
        view.resize(760,620); QTest::qWait(80);
        QVERIFY(view.click("mailBackToMessages"));
        QVERIFY(view.click("mailMessage_fixture-message")); QVERIFY(view.inside("mailReaderPanel"));
        QTRY_VERIFY(!center.detailLoading()); QTest::qWait(30);
        QVERIFY(view.capture("mail-reader-compact"));
        QVERIFY(view.click("mailBackToMessages")); QVERIFY(view.inside("mailMessagesPanel"));
        QVERIFY(view.click("mailCompactCompose")); QVERIFY(center.composing()); QVERIFY(view.inside("mailSendButton"));
        QVERIFY(view.capture("mail-compose-compact"));
        fixture.api.setOnline(false); QTRY_VERIFY(!view.find("mailSendButton")->isEnabled()); QVERIFY(center.hasDraft());
        fixture.api.setOnline(true); QTRY_VERIFY(view.find("mailSendButton")->isEnabled());
        center.closeComposer(); QVERIFY(view.click("mailBackToMessages")); QVERIFY(view.click("mailFilter_unread")); QCOMPARE(center.filter(),QString("unread"));
        QVERIFY2(view.warnings.isEmpty(),qPrintable(view.warnings.join('\n')));
    }
    void mailConnectFlowSupportsGoogleAndPresetImapAtMinimumSize() {
        NativePageFixture fixture; QVERIFY(fixture.remote.server.isListening());
        fixture.remote.responses.insert("POST /api/mail/oauth/google/start",{{"data",QJsonObject{{"flow_id","fixture-flow"},{"authorize_url","https://accounts.google.com/o/oauth2/v2/auth?state=test-only"}}}});
        fixture.remote.responses.insert("GET /api/mail/oauth/fixture-flow",{{"data",QJsonObject{{"status","connected"},{"account_id","fixture-mail"}}}});
        fixture.remote.responses.insert("POST /api/mail/accounts/imap",{{"data",QJsonObject{{"id","fixture-mail"}}}});
        fixture.features.navigate("mail"); QTRY_VERIFY(!fixture.features.busy());
        auto& mail=*qobject_cast<MailAccountsController*>(fixture.features.mailAccounts()); QTRY_VERIFY(!mail.refreshing());
        NativePageView view(fixture,"FeaturePage.qml"); QVERIFY2(view.item,qPrintable(view.failure));
        const auto find=[&view](const QString& name) -> QQuickItem* {
            QList<QQuickItem*> children{view.window.contentItem()};
            for(qsizetype i=0;i<children.size();++i) { if(children[i]->objectName()==name) return children[i]; children.append(children[i]->childItems()); }
            return nullptr;
        };
        const auto click=[&view,&find](const QString& name) -> bool {
            auto* item=find(name); if(!item || !item->isVisible() || item->width()<1 || item->height()<1) return false;
            QTest::mouseClick(&view.window,Qt::LeftButton,Qt::NoModifier,item->mapToScene(QPointF(item->width()/2,item->height()/2)).toPoint()); return true;
        };
        QVERIFY(view.find("emptyConnectMailbox")); QVERIFY(view.click("featurePrimaryButton"));
        QTRY_VERIFY(find("connectGmailButton")); QTRY_VERIFY(find("connectGmailButton")->isVisible());
        QVERIFY(view.capture("mail-connect-choices"));
        QSignalSpy browser(&mail,&MailAccountsController::requestExternal);
        QVERIFY(click("connectGmailButton")); QTRY_COMPARE(browser.count(),1); QVERIFY(mail.oauthPending());
        QVERIFY(view.capture("mail-google-browser"));
        mail.checkOAuth(); QTRY_VERIFY(!mail.oauthPending());
        QVERIFY(view.click("featurePrimaryButton")); QTRY_VERIFY(find("connectImapButton")->isVisible()); QVERIFY(click("connectImapButton"));
        auto* email=find("mailEmail"); auto* password=find("mailPassword"); QVERIFY(email); QVERIFY(password);
        email->setProperty("text","alice@icloud.com"); QVERIFY(QMetaObject::invokeMethod(email,"editingFinished"));
        QCOMPARE(find("mailImapHost")->property("text").toString(),QString("imap.mail.me.com"));
        QCOMPARE(find("mailSmtpHost")->property("text").toString(),QString("smtp.mail.me.com"));
        QCOMPARE(find("mailSmtpPort")->property("text").toString(),QString("587"));
        QCOMPARE(password->property("echoMode").toInt(),2); // TextInput.Password
        view.resize(760,620); QTest::qWait(60);
        auto* submit=find("mailSubmitButton"); QVERIFY(submit); QVERIFY(submit->isVisible());
        const auto location=submit->mapToScene(QPointF()); QVERIFY(location.y()+submit->height()<=620);
        QVERIFY(view.capture("mail-imap-icloud-760"));
        password->setProperty("text","fixture-only-app-password"); QVERIFY(click("mailSubmitButton"));
        QTRY_VERIFY(fixture.remote.requests.contains("/api/mail/accounts/imap")); QTRY_VERIFY(!mail.submitting());
        QTRY_COMPARE(password->property("text").toString(),QString());
        const auto index=fixture.remote.requests.indexOf("/api/mail/accounts/imap");
        QCOMPARE(fixture.remote.bodies.at(index).value("smtp_security").toString(),QString("starttls"));
        QCOMPARE(fixture.remote.bodies.at(index).value("username").toString(),QString("alice@icloud.com"));
        QVERIFY(view.click("featurePrimaryButton")); QTRY_VERIFY(find("connectImapButton")->isVisible()); QVERIFY(click("connectImapButton"));
        password->setProperty("text","fixture-draft-secret"); fixture.api.setWorkspace("different-workspace"); mail.setActive(true);
        QTRY_COMPARE(password->property("text").toString(),QString());
        QVERIFY2(view.warnings.isEmpty(),qPrintable(view.warnings.join('\n')));
    }
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
        QTest::newRow("body-thumbnail-is-not-a-portrait")<<QVariantMap{{"kind","ai"},{"avatar_thumbnail_url","https://assets.invalid/body.png"}}<<QString();
        QTest::newRow("unsafe-portrait-url")<<QVariantMap{{"kind","ai"},{"avatar_portrait_url","file:///private/head.png"}}<<QString();
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
        QVERIFY(portrait->property("portraitSource").toString().isEmpty());
        QCOMPARE(portrait->property("initials").toString(),QString("AL"));
        auto withPortrait=withThumbnail; withPortrait.insert("avatar_portrait_url","https://assets.invalid/avatar-assets/fixture/token/portrait.png");
        QVERIFY(view.page->setProperty("agent",withPortrait));
        QCOMPARE(portrait->property("portraitSource").toString(),withPortrait.value("avatar_portrait_url").toString());
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
        QVERIFY(view.click("agentDetailAssign")); QCOMPARE(fixture.context.testedAgent,QString("fixture-software"));
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
    void marketplaceNavigationFiltersAndDetailsUseRealListings() {
        NativePageFixture fixture;
        fixture.remote.collection("/api/marketplace/listings",marketplaceListings());
        fixture.features.navigate("marketplace"); QTRY_VERIFY(!fixture.features.busy());
        NativePageView view(fixture,"MarketplacePage.qml");
        QVERIFY2(view.item,qPrintable(view.failure)); view.resize(1140,760);
        QTRY_COMPARE(property(view.page.get(),"listings").toList().size(),4);
        QTRY_VERIFY(!fixture.features.busy());
        QVERIFY(view.capture("marketplace-discover-1140"));
        QVERIFY(view.click("marketplaceNav-categories"));
        QTRY_COMPARE(view.page->property("tab").toString(),QString("categories"));
        QVERIFY(view.capture("marketplace-categories-1140"));
        QVERIFY(view.click("marketplaceCategory-legal"));
        QTRY_COMPARE(property(view.page.get(),"listings").toList().size(),1);
        QCOMPARE(property(view.page.get(),"listings").toList().first().toMap().value("id").toString(),QString("listing-legal"));
        QVERIFY(view.click("marketplaceNav-search"));
        QVERIFY(view.page->setProperty("categoryFilter","all"));
        QVERIFY(view.page->setProperty("queryText","software"));
        QTRY_COMPARE(property(view.page.get(),"listings").toList().size(),1);
        QCOMPARE(property(view.page.get(),"listings").toList().first().toMap().value("id").toString(),QString("listing-software"));
        QVERIFY(view.page->setProperty("modeFilter","rent"));
        QTRY_COMPARE(property(view.page.get(),"listings").toList().size(),0);
        QVERIFY(view.page->setProperty("queryText",""));
        QVERIFY(view.page->setProperty("modeFilter","all"));
        QVERIFY(view.page->setProperty("maxPrice",30));
        QTRY_COMPARE(property(view.page.get(),"listings").toList().size(),2);
        QVERIFY(view.capture("marketplace-search-1140"));
        // The filtered model changes synchronously; its GridLayout delegates
        // receive their clickable geometry on the next Qt polish pass.
        QTRY_VERIFY(view.find("marketplaceCard-listing-legal")
            && view.find("marketplaceCard-listing-legal")->isVisible()
            && view.find("marketplaceCard-listing-legal")->width()>1
            && view.find("marketplaceCard-listing-legal")->height()>1);
        QVERIFY(view.click("marketplaceCard-listing-legal"));
        QTRY_COMPARE(view.page->property("screen").toString(),QString("detail"));
        QCOMPARE(property(view.page.get(),"selectedListing").toMap().value("id").toString(),QString("listing-legal"));
        QVERIFY(view.capture("marketplace-detail-1140"));
        view.resize(760,700); QTest::qWait(100);
        QVERIFY(view.inside("marketplaceBuy"));
        QVERIFY(view.capture("marketplace-detail-760"));
        QVERIFY2(view.warnings.isEmpty(),qPrintable(view.warnings.join('\n')));
    }
    void marketplaceCheckoutWaitsForPersistedFulfillment() {
        NativePageFixture fixture;
        fixture.remote.collection("/api/marketplace/listings",marketplaceListings());
        fixture.remote.responses.insert("/api/marketplace/checkout",{{"data",QJsonObject{{"order_id","order-legal"},{"fulfilled",true}}}});
        QJsonObject purchase{{"id","order-legal"},{"listing_id","listing-legal"},{"status","pending"},{"cloned_agent_id",QJsonValue::Null},{"listing",marketplaceListings().first()}};
        fixture.remote.collection("/api/marketplace/purchases",{purchase});
        fixture.features.navigate("marketplace"); QTRY_VERIFY(!fixture.features.busy());
        NativePageView view(fixture,"MarketplacePage.qml");
        QVERIFY2(view.item,qPrintable(view.failure)); view.resize(1140,760);
        QTRY_VERIFY(!fixture.features.busy());
        QVERIFY(view.click("marketplaceCard-listing-legal"));
        QTRY_COMPARE(view.page->property("screen").toString(),QString("detail"));
        QVERIFY(view.click("marketplaceBuy"));
        QTRY_COMPARE(view.page->property("screen").toString(),QString("checkout"));
        QVERIFY(view.capture("marketplace-checkout-1140"));
        view.resize(760,700); QTest::qWait(100);
        QVERIFY(view.inside("marketplaceCheckoutConfirm"));
        QVERIFY(view.capture("marketplace-checkout-760"));
        view.resize(1140,760); QTest::qWait(100);
        QVERIFY(view.click("marketplaceCheckoutConfirm"));
        QTRY_VERIFY(fixture.remote.requests.contains("/api/marketplace/checkout"));
        const auto requestIndex=fixture.remote.requests.indexOf("/api/marketplace/checkout");
        QCOMPARE(fixture.remote.methods.at(requestIndex),QString("POST"));
        QCOMPARE(fixture.remote.bodies.at(requestIndex).value("listing_id").toString(),QString("listing-legal"));
        QTRY_COMPARE(view.page->property("checkoutOrderId").toString(),QString("order-legal"));
        QTRY_VERIFY(!fixture.features.busy());
        QVERIFY(view.click("marketplacePurchaseRefresh"));
        QTRY_VERIFY(fixture.remote.requests.contains("/api/marketplace/purchases"));
        QTRY_VERIFY(!fixture.features.busy());
        QCOMPARE(view.page->property("screen").toString(),QString("checkout"));
        purchase.insert("status","fulfilled");
        fixture.remote.collection("/api/marketplace/purchases",{purchase});
        const auto priorCount=fixture.remote.requests.count("/api/marketplace/purchases");
        QVERIFY(view.click("marketplacePurchaseRefresh"));
        QTRY_VERIFY(fixture.remote.requests.count("/api/marketplace/purchases")>priorCount);
        QTRY_VERIFY(!fixture.features.busy());
        QCOMPARE(view.page->property("screen").toString(),QString("checkout"));
        purchase.insert("cloned_agent_id","purchased-legal");
        fixture.remote.collection("/api/marketplace/purchases",{purchase});
        QVERIFY(view.click("marketplacePurchaseRefresh"));
        QTRY_COMPARE(view.page->property("screen").toString(),QString("success"));
        QCOMPARE(property(view.page.get(),"purchasedOrder").toMap().value("cloned_agent_id").toString(),QString("purchased-legal"));
        QVERIFY(view.capture("marketplace-success-1140"));
        view.resize(760,700); QTest::qWait(100);
        QVERIFY(view.capture("marketplace-success-760"));
        QVERIFY2(view.warnings.isEmpty(),qPrintable(view.warnings.join('\n')));
    }
    void marketplaceSellerWizardValidatesAndPublishesTheSelectedAgent() {
        NativePageFixture fixture;
        const auto listingRows=marketplaceListings();
        QJsonArray mine{
            QJsonObject{{"agent",listingRows.at(0).toObject().value("agent")},{"eligible",true},{"level",12},{"knowledge_item_count",8}},
            QJsonObject{{"agent",listingRows.at(1).toObject().value("agent")},{"listing",listingRows.at(1)},{"eligible",true},{"level",12},{"knowledge_item_count",12}},
            QJsonObject{{"agent",listingRows.at(2).toObject().value("agent")},{"eligible",false},{"level",4},{"knowledge_item_count",2}}
        };
        const QJsonObject meta{{"min_level",10},{"fee_percent",15},{"connect_ready",true}};
        fixture.remote.collection("/api/marketplace/listings",listingRows);
        fixture.remote.responses.insert("/api/marketplace/mine",{{"data",mine},{"meta",meta}});
        fixture.features.navigate("marketplace"); QTRY_VERIFY(!fixture.features.busy());
        NativePageView view(fixture,"MarketplacePage.qml");
        QVERIFY2(view.item,qPrintable(view.failure)); view.resize(1140,760);
        QTRY_VERIFY(!fixture.features.busy());
        QVERIFY(view.click("marketplaceNav-mine"));
        QTRY_COMPARE(property(view.page.get(),"mineRows").toList().size(),3);
        QTRY_VERIFY(!fixture.features.busy());
        QVERIFY(view.capture("marketplace-listings-1140"));
        auto paused=listingRows.at(1).toObject(); paused.insert("status","paused");
        fixture.remote.responses.insert("/api/marketplace/listings/listing-software/pause",{{"data",paused}});
        QVERIFY(QMetaObject::invokeMethod(view.page.get(),"toggleListing",Q_ARG(QVariant,listingRows.at(1).toObject().toVariantMap())));
        QTRY_VERIFY(fixture.remote.requests.contains("/api/marketplace/listings/listing-software/pause"));
        QTRY_VERIFY(!fixture.features.busy());
        QCOMPARE(property(view.page.get(),"mineRows").toList().size(),3);
        QCOMPARE(property(view.page.get(),"mineRows").toList().at(1).toMap().value("listing").toMap().value("status").toString(),QString("paused"));
        fixture.remote.responses.insert("/api/marketplace/listings/listing-software/resume",{{"data",listingRows.at(1)}});
        QVERIFY(QMetaObject::invokeMethod(view.page.get(),"toggleListing",Q_ARG(QVariant,paused.toVariantMap())));
        QTRY_VERIFY(fixture.remote.requests.contains("/api/marketplace/listings/listing-software/resume"));
        QTRY_VERIFY(!fixture.features.busy());
        QCOMPARE(property(view.page.get(),"mineRows").toList().at(1).toMap().value("listing").toMap().value("status").toString(),QString("active"));
        QVERIFY(view.click("marketplaceCreateListing"));
        QTRY_COMPARE(view.page->property("screen").toString(),QString("publish"));
        QCOMPARE(view.page->property("publishAgentId").toString(),QString("source-listing-legal"));
        QVERIFY(view.page->setProperty("publishTitle","Taya · Contract review"));
        QVERIFY(view.page->setProperty("publishDescription","Reviews contracts and highlights relevant clauses."));
        QVERIFY(view.capture("marketplace-publish-1140"));
        view.resize(760,700); QTest::qWait(100);
        QVERIFY(view.inside("marketplacePublishNext"));
        QVERIFY(view.capture("marketplace-publish-760"));
        view.resize(1140,760); QTest::qWait(100);
        QVERIFY(view.click("marketplacePublishNext"));
        auto* seller=view.find("marketplaceSeller"); QVERIFY(seller);
        QTRY_COMPARE(seller->property("wizardStep").toInt(),1);
        QVERIFY(view.click("marketplacePublishNext"));
        QTRY_COMPARE(seller->property("wizardStep").toInt(),2);
        QVERIFY(view.page->setProperty("publishPrice","0.50"));
        QTRY_VERIFY(!view.find("marketplacePublishNext")->isEnabled());
        QVERIFY(view.page->setProperty("publishPrice","49"));
        QTRY_VERIFY(view.find("marketplacePublishNext")->isEnabled());
        QVERIFY(view.click("marketplacePublishNext"));
        QTRY_COMPARE(seller->property("wizardStep").toInt(),3);
        QTRY_VERIFY(view.find("marketplacePublishNext")->isEnabled());
        auto published=listingRows.first().toObject(); published.insert("mode","sale"); published.insert("price_cents",4900); published.insert("title","Taya · Contract review");
        auto updatedMine=mine.first().toObject(); updatedMine.insert("listing",published); mine.replace(0,updatedMine);
        fixture.remote.responses.insert("POST /api/marketplace/listings",{{"data",published}});
        fixture.remote.responses.insert("/api/marketplace/mine",{{"data",mine},{"meta",meta}});
        QVERIFY(view.click("marketplacePublishNext"));
        QTRY_COMPARE(view.page->property("screen").toString(),QString("browse"));
        QTRY_VERIFY(!fixture.features.busy());
        int publishIndex=-1;
        for (qsizetype i=0;i<fixture.remote.requests.size();++i)
            if (fixture.remote.requests.at(i)=="/api/marketplace/listings" && fixture.remote.methods.at(i)=="POST") publishIndex=static_cast<int>(i);
        QVERIFY(publishIndex>=0);
        const auto body=fixture.remote.bodies.at(publishIndex);
        QCOMPARE(body.value("agent_id").toString(),QString("source-listing-legal"));
        QCOMPARE(body.value("title").toString(),QString("Taya · Contract review"));
        QCOMPARE(body.value("description").toString(),QString("Reviews contracts and highlights relevant clauses."));
        QCOMPARE(body.value("price_cents").toInt(),4900);
        QCOMPARE(body.value("mode").toString(),QString("sale"));
        QTRY_COMPARE(property(view.page.get(),"mineRows").toList().first().toMap().value("listing").toMap().value("price_cents").toInt(),4900);
        QJsonArray orders;
        for (int month=0;month<6;++month) orders.append(QJsonObject{{"id",QString("order-%1").arg(month)},
            {"listing_id",month%2?"listing-legal":"listing-software"},{"status","fulfilled"},{"amount_cents",(month+1)*1000},
            {"paid_at",QDateTime::currentDateTimeUtc().addMonths(month-5).toString(Qt::ISODate)}});
        const QJsonObject earningsResponse{{"gross_cents",21000},{"fee_cents",3150},{"net_cents",17850},
            {"fee_percent",15},{"connect_ready",true},{"orders",orders},{"listings",QJsonArray{published,listingRows.at(1)}},
            {"active_leases",QJsonArray{QJsonObject{{"id","lease-legal"},{"status","active"}}}}};
        fixture.remote.responses.insert("/api/marketplace/earnings",{{"data",earningsResponse}});
        QVERIFY(view.click("marketplaceNav-earnings"));
        QTRY_COMPARE(property(view.page.get(),"earningsData").toMap().value("gross_cents").toInt(),21000);
        auto* earnings=view.find("marketplaceEarnings"); QVERIFY(earnings);
        QCOMPARE(property(earnings,"orders").toList().size(),6);
        QCOMPARE(property(earnings,"categories").toList().size(),2);
        int chartGross=0;
        for (const auto& month:property(earnings,"chartMonths").toList()) chartGross+=month.toMap().value("gross").toInt();
        QCOMPARE(chartGross,21000);
        QTest::qWait(100);
        QVERIFY(view.capture("marketplace-earnings-1140"));
        view.resize(760,700); QTest::qWait(100);
        QVERIFY(view.capture("marketplace-earnings-760"));
        QVERIFY2(view.warnings.isEmpty(),qPrintable(view.warnings.join('\n')));
    }
};
int main(int argc,char**argv) {
    qputenv("QT_QPA_PLATFORM","offscreen");
    QQuickWindow::setGraphicsApi(QSGRendererInterface::Software); QQuickStyle::setStyle("Basic");
    QGuiApplication app(argc,argv);
    QTemporaryDir settingsDirectory;
    QCoreApplication::setOrganizationName("MokaidTests");
    QCoreApplication::setApplicationName("NativePages");
    QSettings::setDefaultFormat(QSettings::IniFormat);
    QSettings::setPath(QSettings::IniFormat,QSettings::UserScope,settingsDirectory.path());
    QFontDatabase::addApplicationFont(QStringLiteral(MOKAID_NATIVE_QML_DIRECTORY)+"/../assets/fonts/Manrope.ttf");
    NativePagesQmlTests tests; return QTest::qExec(&tests,argc,argv);
}
#include "native_pages_qml_tests.moc"
