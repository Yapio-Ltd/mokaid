#include <mokaid/features/feature_controller.hpp>
#include <mokaid/features/feature_catalog.hpp>
#include <QFile>
#include <QBuffer>
#include <QDir>
#include <QImage>
#include <QPainter>
#include <QGuiApplication>
#include <QFontDatabase>
#include <QJsonDocument>
#include <QJSValue>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QtTest>
#include <memory>

using namespace mokaid::desktop;
class ActionFormFixture final : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool busy READ busy NOTIFY changed)
    Q_PROPERTY(QString error READ error NOTIFY changed)
    Q_PROPERTY(QString currentPage MEMBER currentPage NOTIFY changed)
public:
    bool busy() const { return false; }
    QString error() const { return {}; }
    QVariantMap submitted;
    bool agentCreation{false};
    int submissions{0};
    QString currentPage{"tasks"};
    QString selectedId{"developer"};
    Q_INVOKABLE QString actionContext(const QString& action) const { return "fixture:"+action; }
    Q_INVOKABLE QVariantList fieldsForAction(const QString& action) const {
        if (agentCreation) {
            // Exercise the production field schema, including hidden required
            // defaults; the fixture only supplies the selected catalog key.
            const auto definition=findFeature("agent-new")->actions.front();
            auto fields=definition.fields;
            for (auto& value:fields) {
                auto field=value.toMap(); const auto key=field.value("key").toString();
                if (definition.defaults.contains(key)) field.insert("value",definition.defaults.value(key));
                if (key=="archetype_key") field.insert("value",selectedId);
                value=field;
            }
            return fields;
        }
        if (action == "second") return {QVariantMap{{"key","title"},{"label","Title"},{"type","string"},{"value","Second initial title"}}};
        return {QVariantMap{{"key","title"},{"label","Title"},{"type","string"},{"value","Initial title"}},
                QVariantMap{{"key","description"},{"label","Description"},{"type","multiline"},{"value","Initial description"}},
                QVariantMap{{"key","configuration"},{"label","Configuration"},{"type","json"},{"value",QVariantMap{{"enabled",true}}}},
                QVariantMap{{"key","optional"},{"label","Optional"},{"type","string"}}};
    }
    Q_INVOKABLE void submit(const QString&, const QVariantMap& values) { submitted=values; ++submissions; }
    Q_INVOKABLE void navigate(const QString& page) { currentPage=page; emit changed(); }
signals:
    void changed();
    void actionSucceeded(QString context);
};

class DeliveryPreviewFixture final : public QObject {
    Q_OBJECT
    Q_PROPERTY(int thumbnailRevision READ thumbnailRevision CONSTANT)
public:
    int thumbnailRevision() const { return 1; }
    QVariantList opened;
    int openedIndex{-1};
    Q_INVOKABLE QVariantMap describe(const QVariantMap& file) const {
        const auto mime=file.value("mime_type").toString();
        const auto kind=mime.startsWith("image/")?QString("image"):mime=="text/html"?QString("html"):QString("pdf");
        return {{"kind",kind},{"label",kind=="image"?"Image":kind=="html"?"Web page":"PDF"},{"extension",kind},{"sizeLabel","240 KB"}};
    }
    Q_INVOKABLE QString thumbnailState(const QVariantMap&) const { return "ready"; }
    Q_INVOKABLE QString thumbnailUrl(const QVariantMap& file) const {
        if (!file.value("mime_type").toString().startsWith("image/")) return {};
        // Deterministic synthetic artwork, used only to exercise real image decoding.
        QImage image(640,440,QImage::Format_RGB32);
        image.fill(file.value("id").toString()=="image-one"?QColor("#f2dfc2"):QColor("#cadcd9"));
        QPainter painter(&image); painter.setPen(Qt::NoPen); painter.setBrush(QColor("#475959"));
        painter.drawRoundedRect(QRectF(248,80,144,280),60,60);
        painter.setBrush(QColor("#eaeae1")); painter.drawRect(QRectF(248,180,144,120));
        painter.setPen(QColor("#333f3d")); QFont font; font.setPixelSize(24); painter.setFont(font);
        painter.drawText(QRectF(248,180,144,120),Qt::AlignCenter,"SAMPLE"); painter.end();
        QByteArray bytes; QBuffer buffer(&bytes); buffer.open(QIODevice::WriteOnly); image.save(&buffer,"PNG");
        return "data:image/png;base64,"+QString::fromLatin1(bytes.toBase64());
    }
    Q_INVOKABLE void openCollection(const QVariantList& files,int index) { opened=files; openedIndex=index; }
};

class FeatureQmlTests final : public QObject {
    Q_OBJECT
    static QVariantMap values(QObject* dialog) {
        const auto value=dialog->property("values");
        return value.metaType()==QMetaType::fromType<QJSValue>()?value.value<QJSValue>().toVariant().toMap():value.toMap();
    }
    static QList<QQuickItem*> visualItems(QQuickItem* root) {
        QList<QQuickItem*> items{root};
        for (qsizetype index=0;index<items.size();++index) items.append(items[index]->childItems());
        return items;
    }
    static QQuickItem* editor(QQuickItem* root,const QString& text) {
        for (auto* item : visualItems(root))
            if (item->property("text").toString()==text && item->property("selectByMouse").isValid()) return item;
        return nullptr;
    }
    static QQuickItem* visualItem(QQuickItem* root,const QString& name) {
        for (auto* item : visualItems(root)) if (item->objectName()==name) return item;
        return nullptr;
    }
private slots:
    void agentCreationFormPreservesSpecialtyAndSubmitsUserChoices() {
        QTemporaryDir staging; QVERIFY(staging.isValid());
        for (const auto& file:QDir(QStringLiteral(MOKAID_FEATURE_QML_DIRECTORY)).entryList({"*.qml","*.js"},QDir::Files))
            QVERIFY(QFile::copy(QStringLiteral(MOKAID_FEATURE_QML_DIRECTORY)+"/"+file,staging.path()+"/"+file));
        QFile qmldir(staging.path()+"/qmldir"); QVERIFY(qmldir.open(QIODevice::WriteOnly));
        qmldir.write("singleton Theme 1.0 Theme.qml\n"); qmldir.close();
        ActionFormFixture features; features.agentCreation=true; features.currentPage="agent-new";
        QQmlEngine engine; QStringList warnings;
        connect(&engine,&QQmlEngine::warnings,this,[&](const QList<QQmlError>& errors) { for (const auto& error:errors) warnings.append(error.toString()); });
        engine.rootContext()->setContextProperty("features",&features);
        QQmlComponent component(&engine);
        component.setData("import QtQuick\nRectangle { width: 1000; height: 820; color: Theme.background; ActionDialog { objectName: \"creationDialog\" } }",QUrl::fromLocalFile(staging.path()+"/AgentCreationFixture.qml"));
        std::unique_ptr<QObject> root(component.create()); QVERIFY2(root,qPrintable(component.errorString()));
        auto* item=qobject_cast<QQuickItem*>(root.get()); QVERIFY(item);
        QQuickWindow window; window.resize(1000,820); item->setParentItem(window.contentItem()); window.show();
        auto* dialog=root->findChild<QObject*>("creationDialog"); QVERIFY(dialog);
        const QVariant action=QVariantMap{{"id","create"},{"title","Create agent"},{"enabled",true},{"specialization",QVariantMap{{"key","developer"},{"name","Developer"},{"role_title","Software Engineer"},{"department","Engineering"}}}};
        QVERIFY(QMetaObject::invokeMethod(dialog,"showAction",Q_ARG(QVariant,action)));
        QTRY_VERIFY(dialog->property("opened").toBool());
        QVERIFY(dialog->property("agentCreation").toBool());
        auto* submit=visualItem(window.contentItem(),"creationSubmit"); QVERIFY(submit); QVERIFY(!submit->isEnabled());
        QCOMPARE(values(dialog).value("archetype_key").toString(),QString("developer"));
        QCOMPARE(values(dialog).value("kind").toString(),QString("ai"));
        QCOMPARE(values(dialog).value("role_title").toString(),QString("Software Engineer"));
        QCOMPARE(values(dialog).value("department").toString(),QString("Engineering"));
        auto* name=visualItem(window.contentItem(),"creationNameField"); QVERIFY(name); QVERIFY(name->isVisible());
        QVERIFY(name->setProperty("text","Draft teammate")); QTRY_VERIFY(submit->isEnabled());
        auto* cancel=visualItem(window.contentItem(),"actionCancel"); QVERIFY(cancel); QVERIFY(QMetaObject::invokeMethod(cancel,"clicked"));
        QTRY_VERIFY(!dialog->property("opened").toBool()); QCOMPARE(features.submissions,0);
        QCOMPARE(features.currentPage,QString("agent-new")); QCOMPARE(features.selectedId,QString("developer"));

        QVERIFY(QMetaObject::invokeMethod(dialog,"showAction",Q_ARG(QVariant,action))); QTRY_VERIFY(dialog->property("opened").toBool());
        submit=visualItem(window.contentItem(),"creationSubmit"); QVERIFY(submit); QVERIFY(!submit->isEnabled());
        name=visualItem(window.contentItem(),"creationNameField"); QVERIFY(name);
        auto* instructions=visualItem(window.contentItem(),"actionField_instructions"); QVERIFY(instructions);
        // Accessibility tools set text directly, without the keyboard textEdited signal.
        QVERIFY(name->setProperty("text","Dev teammate"));
        QVERIFY(instructions->setProperty("text","Review pull requests and explain the tradeoffs."));
        auto* supervised=visualItem(window.contentItem(),"creationChoice_autonomy_mode_supervised"); QVERIFY(supervised);
        auto* fast=visualItem(window.contentItem(),"creationChoice_model_quality_fast"); QVERIFY(fast);
        QVERIFY(QMetaObject::invokeMethod(supervised,"clicked")); QVERIFY(QMetaObject::invokeMethod(fast,"clicked"));
        QVERIFY(supervised->property("highlighted").toBool()); QVERIFY(fast->property("highlighted").toBool());
        QVERIFY(!visualItem(window.contentItem(),"creationChoice_autonomy_mode_balanced")->property("highlighted").toBool());
        const auto captureDirectory=qEnvironmentVariable("MOKAID_NATIVE_CAPTURE_DIR");
        QTest::qWait(40);
        if (!captureDirectory.isEmpty()) { QDir().mkpath(captureDirectory); QVERIFY(window.grabWindow().save(captureDirectory+"/agent-customization-wide.png")); }
        window.resize(750,580); item->setSize(QSizeF(750,580)); QTest::qWait(40);
        QVERIFY(dialog->property("height").toReal()<=532); QVERIFY(submit->isVisible());
        if (!captureDirectory.isEmpty()) QVERIFY(window.grabWindow().save(captureDirectory+"/agent-customization-minimum.png"));
        QVERIFY(QMetaObject::invokeMethod(submit,"clicked")); QCOMPARE(features.submissions,1);
        QCOMPARE(features.submitted.value("display_name").toString(),QString("Dev teammate"));
        QCOMPARE(features.submitted.value("instructions").toString(),QString("Review pull requests and explain the tradeoffs."));
        QCOMPARE(features.submitted.value("archetype_key").toString(),QString("developer"));
        QCOMPARE(features.submitted.value("kind").toString(),QString("ai"));
        QCOMPARE(features.submitted.value("autonomy_mode").toString(),QString("supervised"));
        QCOMPARE(features.submitted.value("model_quality").toString(),QString("fast"));
        QVERIFY(!features.submitted.contains("boost_key"));
        emit features.actionSucceeded("fixture:create");
        QTRY_VERIFY(!dialog->property("opened").toBool()); QCOMPARE(features.currentPage,QString("agents"));
        QVERIFY2(warnings.isEmpty(),qPrintable(warnings.join('\n')));
        item->setParentItem(nullptr);
    }
    void deliverableGalleryShowsActualImagesAndOpensTheirCollection() {
        QTemporaryDir staging; QVERIFY(staging.isValid());
        for (const auto& file : QDir(QStringLiteral(MOKAID_FEATURE_QML_DIRECTORY)).entryList({"*.qml", "*.js"}, QDir::Files))
            QVERIFY(QFile::copy(QStringLiteral(MOKAID_FEATURE_QML_DIRECTORY)+"/"+file,staging.path()+"/"+file));
        QFile qmldir(staging.path()+"/qmldir"); QVERIFY(qmldir.open(QIODevice::WriteOnly));
        qmldir.write("singleton Theme 1.0 Theme.qml\n"); qmldir.close();
        DeliveryPreviewFixture preview;
        QVariantList files{QVariantMap{{"id","image-one"},{"name","Product campaign — warm light.png"},{"mime_type","image/png"}},
            QVariantMap{{"id","report"},{"name","Campaign strategy.html"},{"mime_type","text/html"}},
            QVariantMap{{"id","image-two"},{"name","Product campaign — cool light.png"},{"mime_type","image/png"}}};
        QQmlEngine engine; QStringList warnings;
        connect(&engine,&QQmlEngine::warnings,this,[&](const QList<QQmlError>& errors) { for (const auto& error : errors) warnings.append(error.toString()); });
        engine.rootContext()->setContextProperty("preview",&preview);
        engine.rootContext()->setContextProperty("galleryFiles",files);
        QQmlComponent component(&engine);
        component.setData("import QtQuick\nRectangle { color: Theme.background; DeliveryGallery { objectName: \"gallery\"; anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 24; files: galleryFiles } }",QUrl::fromLocalFile(staging.path()+"/GalleryFixture.qml"));
        std::unique_ptr<QObject> page(component.create()); QVERIFY2(page,qPrintable(component.errorString()));
        auto* item=qobject_cast<QQuickItem*>(page.get()); QVERIFY(item);
        QQuickWindow window; window.resize(640,560); item->setParentItem(window.contentItem()); item->setSize(QSizeF(640,560)); window.show();
        auto readyImages=[&] {
            int ready=0;
            for (auto* child : visualItems(item)) if (child->objectName()=="deliveryThumbnail" && child->property("status").toInt()==1) ++ready;
            return ready;
        };
        QTRY_COMPARE(readyImages(),2);
        auto* second=visualItem(item,"deliveryCard_image-two"); QVERIFY(second);
        second->forceActiveFocus(); QTest::keyClick(&window,Qt::Key_Return);
        QCOMPARE(preview.openedIndex,2); QCOMPARE(preview.opened,files);
        auto* report=visualItem(item,"deliveryCard_report"); QVERIFY(report);
        QTest::mouseClick(&window,Qt::LeftButton,Qt::NoModifier,report->mapToScene(QPointF(report->width()/2,report->height()/2)).toPoint());
        QCOMPARE(preview.openedIndex,1);
        const auto captureDirectory=qEnvironmentVariable("MOKAID_DELIVERY_CAPTURE_DIR");
        if (!captureDirectory.isEmpty()) { QDir().mkpath(captureDirectory); QVERIFY(window.grabWindow().save(captureDirectory+"/gallery-wide.png")); }
        window.resize(320,780); item->setSize(QSizeF(320,780)); QTest::qWait(30);
        for (auto* child : visualItems(item)) {
            if (!child->objectName().startsWith("deliveryCard_")) continue;
            const auto origin=child->mapToItem(item,QPointF());
            QVERIFY(origin.x()>=0); QVERIFY(origin.x()+child->width()<=item->width()+1);
            QVERIFY(child->width()>0); QVERIFY(child->height()>0);
        }
        if (!captureDirectory.isEmpty()) QVERIFY(window.grabWindow().save(captureDirectory+"/gallery-narrow.png"));
        QVERIFY2(warnings.isEmpty(),qPrintable(warnings.join('\n')));
        item->setParentItem(nullptr);
    }
    void driveToolbarSupportsKeyboardFoldersBreadcrumbsAndTrash() {
        QTemporaryDir staging, cacheDirectory; QVERIFY(staging.isValid()); QVERIFY(cacheDirectory.isValid());
        for (const auto& file : QDir(QStringLiteral(MOKAID_FEATURE_QML_DIRECTORY)).entryList({"*.qml", "*.js"}, QDir::Files))
            QVERIFY(QFile::copy(QStringLiteral(MOKAID_FEATURE_QML_DIRECTORY)+"/"+file,staging.path()+"/"+file));
        QFile qmldir(staging.path()+"/qmldir"); QVERIFY(qmldir.open(QIODevice::WriteOnly));
        qmldir.write("singleton Theme 1.0 Theme.qml\n"); qmldir.close();
        QTcpServer server; QVERIFY(server.listen(QHostAddress::LocalHost,0));
        const QByteArray folder=R"({"id":"folder-a","name":"<b>Plain folder</b>","kind":"folder","status":"active"})";
        QStringList paths;
        connect(&server,&QTcpServer::newConnection,this,[&] {
            while (server.hasPendingConnections()) {
                auto* socket=server.nextPendingConnection(); connect(socket,&QTcpSocket::disconnected,socket,&QObject::deleteLater);
                connect(socket,&QTcpSocket::readyRead,this,[&,socket] {
                    const auto bytes=socket->property("request").toByteArray()+socket->readAll(); socket->setProperty("request",bytes);
                    if (!bytes.contains("\r\n\r\n") || socket->property("handled").toBool()) return;
                    socket->setProperty("handled",true); const auto path=QString::fromUtf8(bytes.split(' ').value(1)); paths.append(path);
                    const QByteArray body=path=="/api/drive" ? "{\"data\":["+folder+"]}"
                        : path=="/api/drive/folder-a" ? "{\"data\":"+folder+"}"
                        : QByteArrayLiteral("{\"data\":[]}");
                    socket->write("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: "+QByteArray::number(body.size())+"\r\n\r\n"+body); socket->disconnectFromHost();
                });
            }
        });
        ApiClient api(QUrl(QString("http://127.0.0.1:%1").arg(server.serverPort()))); api.setSession("test-alice","alice",false); api.setWorkspace("workspace-a");
        PhoenixClient realtime; SessionController session(api,realtime); CacheStore cache(cacheDirectory.path()); FeatureController features(api,session,cache);
        features.navigate("drive"); QTRY_COMPARE(features.records()->rowCount(),1);
        QQmlEngine engine; QStringList warnings;
        connect(&engine,&QQmlEngine::warnings,this,[&](const QList<QQmlError>& errors) { for (const auto& error : errors) warnings.append(error.toString()); });
        engine.rootContext()->setContextProperty("features",&features);
        QQmlComponent component(&engine);
        component.setData("import QtQuick\nItem { FeaturePage { anchors.fill: parent; onActionRequested: function(action) { form.showAction(action) } } ActionDialog { id: form; objectName: \"driveActionDialog\" } }",QUrl::fromLocalFile(staging.path()+"/DriveFixture.qml"));
        std::unique_ptr<QObject> page(component.create()); QVERIFY2(page,qPrintable(component.errorString())); auto* item=qobject_cast<QQuickItem*>(page.get()); QVERIFY(item);
        QQuickWindow window; window.resize(1180,760); item->setParentItem(window.contentItem()); item->setSize(QSizeF(1180,760)); window.show(); QTest::qWait(50);
        QQuickItem* row=nullptr;
        for (auto* candidate : visualItems(item)) if (candidate->property("rowId").toString()=="folder-a") { row=candidate; break; }
        QVERIFY(row); row->forceActiveFocus(); QTest::keyClick(&window,Qt::Key_Return);
        QTRY_VERIFY(paths.contains("/api/drive/folder-a/children")); QTRY_VERIFY(!features.busy()); QCOMPARE(features.driveBreadcrumbs().size(),2);
        QObject* crumb=nullptr;
        for (auto* candidate : visualItems(item)) if (candidate->objectName()=="driveBreadcrumb1") { crumb=candidate; break; }
        QVERIFY(crumb); QCOMPARE(crumb->property("text").toString(),QString("<b>Plain folder</b>"));
        const auto content=qobject_cast<QQuickItem*>(crumb->property("contentItem").value<QObject*>()); QVERIFY(content);
        QQuickItem* breadcrumbText=nullptr;
        for (auto* candidate : visualItems(content))
            if (candidate->property("text").toString()=="<b>Plain folder</b>" && candidate->property("textFormat").isValid()) { breadcrumbText=candidate; break; }
        QVERIFY(breadcrumbText); QCOMPARE(breadcrumbText->property("textFormat").toInt(),0);
        auto* trash=page->findChild<QQuickItem*>("driveTrash"); QVERIFY(trash);
        auto* form=page->findChild<QObject*>("driveActionDialog"); QVERIFY(form);
        QVariant create;
        for (const auto& action : features.actions()) if (action.toMap().value("id")=="create") create=action;
        QVERIFY(create.isValid()); QVERIFY(QMetaObject::invokeMethod(form,"showAction",Q_ARG(QVariant,create))); QTRY_VERIFY(form->property("opened").toBool());
        QVERIFY(QMetaObject::invokeMethod(form,"setValue",Q_ARG(QVariant,QVariant("name")),Q_ARG(QVariant,QVariant("Unsaved synthetic folder"))));
        QTest::mouseClick(&window,Qt::LeftButton,Qt::NoModifier,trash->mapToScene(QPointF(trash->width()/2,trash->height()/2)).toPoint());
        QTest::qWait(30); QVERIFY(!features.driveTrash()); QVERIFY(form->property("opened").toBool());
        QCOMPARE(values(form).value("name").toString(),QString("Unsaved synthetic folder")); QCOMPARE(values(form).value("parent_id").toString(),QString("folder-a"));
        const auto requestsBeforeTransition=paths.size();
        features.navigateDriveBreadcrumb(0); QTRY_VERIFY(!features.busy());
        QVERIFY(form->property("contextExpired").toBool()); QVERIFY(!form->property("contextError").toString().isEmpty()); QVERIFY(values(form).isEmpty());
        QCOMPARE(paths.size(),requestsBeforeTransition+1); QVERIFY(form->property("opened").toBool());
        QVERIFY(QMetaObject::invokeMethod(form,"close")); QTRY_VERIFY(!form->property("opened").toBool());
        features.openDriveFolder("folder-a"); QTRY_VERIFY(!features.busy());
        QVERIFY(QMetaObject::invokeMethod(trash,"clicked"));
        QTRY_VERIFY(features.driveTrash()); QTRY_VERIFY(!features.busy()); QVERIFY(paths.contains("/api/drive-trash"));
        auto* save=page->findChild<QObject*>("driveDownload"); QVERIFY(save); QVERIFY(!save->property("enabled").toBool());
        auto* back=page->findChild<QObject*>("driveBack"); QVERIFY(back); QVERIFY(QMetaObject::invokeMethod(back,"clicked"));
        QTRY_VERIFY(!features.driveTrash()); QTRY_VERIFY(!features.busy()); QCOMPARE(features.driveFolderId(),QString("folder-a"));
        QVERIFY(QMetaObject::invokeMethod(back,"clicked")); QTRY_VERIFY(!features.busy()); QVERIFY(features.driveFolderId().isEmpty());
        auto* dialog=page->findChild<QObject*>("driveSaveDialog"); QVERIFY(dialog); QCOMPARE(dialog->property("options").toInt(),0);
        QVERIFY2(warnings.isEmpty(),qPrintable(warnings.join('\n'))); item->setParentItem(nullptr);
    }
    void actionDialogCapturesAccessibilityAndKeyboardTextChanges() {
        QTemporaryDir staging; QVERIFY(staging.isValid());
        for (const auto& file : QDir(QStringLiteral(MOKAID_FEATURE_QML_DIRECTORY)).entryList({"*.qml", "*.js"}, QDir::Files))
            QVERIFY(QFile::copy(QStringLiteral(MOKAID_FEATURE_QML_DIRECTORY)+"/"+file,staging.path()+"/"+file));
        QFile qmldir(staging.path()+"/qmldir"); QVERIFY(qmldir.open(QIODevice::WriteOnly));
        qmldir.write("singleton Theme 1.0 Theme.qml\n"); qmldir.close();
        ActionFormFixture features; QQmlEngine engine; QStringList warnings;
        connect(&engine,&QQmlEngine::warnings,this,[&](const QList<QQmlError>& errors) { for (const auto& error : errors) warnings.append(error.toString()); });
        engine.rootContext()->setContextProperty("features",&features);
        QQmlComponent component(&engine);
        component.setData("import QtQuick\nItem { width: 900; height: 800; ActionDialog { objectName: \"actionDialog\" } }",QUrl::fromLocalFile(staging.path()+"/ActionFixture.qml"));
        std::unique_ptr<QObject> root(component.create()); QVERIFY2(root,qPrintable(component.errorString()));
        auto* item=qobject_cast<QQuickItem*>(root.get()); QVERIFY(item);
        QQuickWindow window; window.resize(900,800); item->setParentItem(window.contentItem()); window.show();
        auto* dialog=root->findChild<QObject*>("actionDialog"); QVERIFY(dialog);
        const QVariant action=QVariantMap{{"id","create"},{"title","Create task"},{"enabled",true}};
        QVERIFY(QMetaObject::invokeMethod(dialog,"showAction",Q_ARG(QVariant,action)));
        QTRY_VERIFY(dialog->property("opened").toBool());
        QCOMPARE(values(dialog).value("title").toString(),QString("Initial title"));
        QCOMPARE(values(dialog).value("configuration").toMap(),(QVariantMap{{"enabled",true}}));
        QVERIFY(!values(dialog).contains("optional"));
        auto* title=editor(window.contentItem(),"Initial title"); QVERIFY(title);
        auto* description=editor(window.contentItem(),"Initial description"); QVERIFY(description);
        QVERIFY(!title->hasActiveFocus()); QVERIFY(!description->hasActiveFocus());
        QSignalSpy valueChanges(dialog,SIGNAL(valuesChanged())); QVERIFY(valueChanges.isValid());
        // QAccessible's value interface updates the text property without the
        // keyboard-only textEdited signal. Reproduce that path without focus.
        QVERIFY(title->setProperty("text","Accessibility title"));
        QVERIFY(description->setProperty("text","Accessibility description"));
        QCOMPARE(values(dialog).value("title").toString(),QString("Accessibility title"));
        QCOMPARE(values(dialog).value("description").toString(),QString("Accessibility description"));
        QCOMPARE(values(dialog).value("configuration").toMap(),(QVariantMap{{"enabled",true}}));
        QCOMPARE(valueChanges.count(),2);
        QObject* submit=nullptr;
        for (auto* object : visualItems(window.contentItem()))
            if (object->property("text").toString()=="Create task" && object->metaObject()->indexOfSignal("clicked()")>=0) submit=object;
        QVERIFY(submit); QVERIFY(QMetaObject::invokeMethod(submit,"clicked"));
        QCOMPARE(features.submitted.value("title").toString(),QString("Accessibility title"));
        QCOMPARE(features.submitted.value("description").toString(),QString("Accessibility description"));
        QVERIFY(QMetaObject::invokeMethod(dialog,"setValue",Q_ARG(QVariant,QVariant("title")),Q_ARG(QVariant,QVariant("Model refreshed title"))));
        QCOMPARE(title->property("text").toString(),QString("Model refreshed title"));
        QCOMPARE(valueChanges.count(),3);
        QVERIFY(QMetaObject::invokeMethod(dialog,"setValue",Q_ARG(QVariant,QVariant("title")),Q_ARG(QVariant,QVariant("Model refreshed title"))));
        QCOMPARE(valueChanges.count(),3);
        title->forceActiveFocus();
        QVERIFY(QMetaObject::invokeMethod(title,"selectAll"));
        for (const auto character : QByteArray("Keyboard title")) QTest::keyClick(&window,character);
        QCOMPARE(values(dialog).value("title").toString(),QString("Keyboard title"));
        QVERIFY(submit); QVERIFY(QMetaObject::invokeMethod(submit,"clicked"));
        QCOMPARE(features.submitted.value("title").toString(),QString("Keyboard title"));
        QCOMPARE(features.submitted.value("description").toString(),QString("Accessibility description"));
        QVERIFY(QMetaObject::invokeMethod(dialog,"close"));
        const QVariant second=QVariantMap{{"id","second"},{"title","Update task"},{"enabled",true}};
        QVERIFY(QMetaObject::invokeMethod(dialog,"showAction",Q_ARG(QVariant,second)));
        QTRY_VERIFY(editor(window.contentItem(),"Second initial title"));
        QCOMPARE(values(dialog).value("title").toString(),QString("Second initial title"));
        QVERIFY(!values(dialog).contains("description"));
        QVERIFY2(warnings.isEmpty(),qPrintable(warnings.join('\n')));
        item->setParentItem(nullptr);
    }
    void realFeaturePageRendersNestedPayload() {
        QTemporaryDir staging, cacheDirectory; QVERIFY(staging.isValid()); QVERIFY(cacheDirectory.isValid());
        for (const auto& file : QDir(QStringLiteral(MOKAID_FEATURE_QML_DIRECTORY)).entryList({"*.qml", "*.js"}, QDir::Files))
            QVERIFY(QFile::copy(QStringLiteral(MOKAID_FEATURE_QML_DIRECTORY)+"/"+file,staging.path()+"/"+file));
        QFile qmldir(staging.path()+"/qmldir"); QVERIFY(qmldir.open(QIODevice::WriteOnly));
        qmldir.write("singleton Theme 1.0 Theme.qml\n"); qmldir.close();
        QTcpServer server; QVERIFY(server.listen(QHostAddress::LocalHost,0));
        const QByteArray task=R"({"id":"task1","title":"Report <b>plain text</b>","description":"Real API fixture","status":"completed","comments":[{"id":"comment1","body":"Full review comment","author_name":"Alice"}],"attachments":[{"id":"image-one","name":"Campaign visual.png","mime_type":"image/png","source":"output"},{"id":"input-one","name":"Source brief.pdf","mime_type":"application/pdf","source":"input"}],"latest_run":{"id":"run1","status":"completed","output":{"summary":"Produced report"}}})";
        connect(&server,&QTcpServer::newConnection,this,[&] {
            while (server.hasPendingConnections()) {
                auto* socket=server.nextPendingConnection(); connect(socket,&QTcpSocket::disconnected,socket,&QObject::deleteLater);
                connect(socket,&QTcpSocket::readyRead,this,[socket,task] {
                    const auto bytes=socket->property("request").toByteArray()+socket->readAll(); socket->setProperty("request",bytes);
                    if (!bytes.contains("\r\n\r\n") || socket->property("handled").toBool()) return;
                    socket->setProperty("handled",true);
                    const auto body=bytes.startsWith("GET /api/tasks/task1 ")?"{\"data\":"+task+"}":"{\"data\":["+task+"]}";
                    socket->write("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: "+QByteArray::number(body.size())+"\r\n\r\n"+body); socket->disconnectFromHost();
                });
            }
        });
        ApiClient api(QUrl(QString("http://127.0.0.1:%1").arg(server.serverPort())));
        api.setSession("test-alice","alice",false); api.setWorkspace("workspace-a");
        PhoenixClient realtime; SessionController session(api,realtime); CacheStore cache(cacheDirectory.path()); FeatureController features(api,session,cache);
        features.openRecord("tasks","task1"); QTRY_VERIFY(features.details().contains("latest_run"));
        DeliveryPreviewFixture preview; QQmlEngine engine; QStringList warnings;
        connect(&engine,&QQmlEngine::warnings,this,[&](const QList<QQmlError>& errors) { for (const auto& error : errors) warnings.append(error.toString()); });
        engine.rootContext()->setContextProperty("features",&features);
        engine.rootContext()->setContextProperty("preview",&preview);
        QQmlComponent component(&engine,QUrl::fromLocalFile(staging.path()+"/FeaturePage.qml"));
        std::unique_ptr<QObject> page(component.create()); QVERIFY2(page,qPrintable(component.errorString()));
        auto* item=qobject_cast<QQuickItem*>(page.get()); QVERIFY(item);
        QQuickWindow window; window.setColor(QColor("#0b0b10")); window.resize(1180,760); item->setParentItem(window.contentItem()); item->setSize(QSizeF(1180,760)); window.show();
        QTest::qWait(100);
        QVERIFY(!page->property("metadataExpanded").toBool());
        QVERIFY(visualItem(item,"deliveryCard_image-one"));
        QVERIFY(!visualItem(item,"deliveryCard_input-one"));
        auto* thumbnail=visualItem(item,"deliveryThumbnail"); QVERIFY(thumbnail);
        QTRY_COMPARE(thumbnail->property("status").toInt(),1); // Image.Ready
        const auto captureDirectory=qEnvironmentVariable("MOKAID_DELIVERY_CAPTURE_DIR");
        if (!captureDirectory.isEmpty()) {
            QDir().mkpath(captureDirectory);
            QVERIFY(window.grabWindow().save(captureDirectory+"/task-deliverables.png"));
        }
        auto* browser=qobject_cast<DetailBrowser*>(features.detailView()); QVERIFY(browser);
        browser->enter("comments"); QTest::qWait(50); QCOMPARE(browser->rows()->rowCount(),1);
        browser->enter("comments/0"); QTest::qWait(50); QCOMPARE(browser->rows()->rowCount(),3);
        browser->goTo(0); QTest::qWait(50);
        QVERIFY2(warnings.isEmpty(),qPrintable(warnings.join('\n')));
        QVERIFY(!window.grabWindow().isNull());
        item->setParentItem(nullptr);
    }
};
int main(int argc,char** argv) {
    qputenv("QT_QPA_PLATFORM","offscreen");
    QQuickWindow::setGraphicsApi(QSGRendererInterface::Software);
    QQuickStyle::setStyle("Basic");
    QGuiApplication app(argc,argv);
    QFontDatabase::addApplicationFont(QStringLiteral(MOKAID_FEATURE_QML_DIRECTORY)+"/../assets/fonts/Manrope.ttf");
    FeatureQmlTests tests; return QTest::qExec(&tests,argc,argv);
}
#include "feature_qml_tests.moc"
