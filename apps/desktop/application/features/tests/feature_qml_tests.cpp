#include <mokaid/features/feature_controller.hpp>
#include <QFile>
#include <QGuiApplication>
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
public:
    bool busy() const { return false; }
    QString error() const { return {}; }
    QVariantMap submitted;
    Q_INVOKABLE QVariantList fieldsForAction(const QString& action) const {
        if (action == "second") return {QVariantMap{{"key","title"},{"label","Title"},{"type","string"},{"value","Second initial title"}}};
        return {QVariantMap{{"key","title"},{"label","Title"},{"type","string"},{"value","Initial title"}},
                QVariantMap{{"key","description"},{"label","Description"},{"type","multiline"},{"value","Initial description"}},
                QVariantMap{{"key","configuration"},{"label","Configuration"},{"type","json"},{"value",QVariantMap{{"enabled",true}}}},
                QVariantMap{{"key","optional"},{"label","Optional"},{"type","string"}}};
    }
    Q_INVOKABLE void submit(const QString&, const QVariantMap& values) { submitted=values; }
signals:
    void changed();
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
private slots:
    void actionDialogCapturesAccessibilityAndKeyboardTextChanges() {
        QTemporaryDir staging; QVERIFY(staging.isValid());
        for (const auto& file : {"ActionDialog.qml","Theme.qml","MokaidLabel.qml","MokaidButton.qml","MokaidTextField.qml","MokaidTextArea.qml","MokaidComboBox.qml"})
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
        for (const auto& file : {"FeaturePage.qml","Theme.qml","MokaidLabel.qml","MokaidButton.qml","MokaidTextField.qml"})
            QVERIFY(QFile::copy(QStringLiteral(MOKAID_FEATURE_QML_DIRECTORY)+"/"+file,staging.path()+"/"+file));
        QFile qmldir(staging.path()+"/qmldir"); QVERIFY(qmldir.open(QIODevice::WriteOnly));
        qmldir.write("singleton Theme 1.0 Theme.qml\n"); qmldir.close();
        QTcpServer server; QVERIFY(server.listen(QHostAddress::LocalHost,0));
        const QByteArray task=R"({"id":"task1","title":"Report <b>plain text</b>","description":"Real API fixture","status":"completed","comments":[{"id":"comment1","body":"Full review comment","author_name":"Alice"}],"latest_run":{"id":"run1","status":"completed","output":{"summary":"Produced report"}}})";
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
        QQmlEngine engine; QStringList warnings;
        connect(&engine,&QQmlEngine::warnings,this,[&](const QList<QQmlError>& errors) { for (const auto& error : errors) warnings.append(error.toString()); });
        engine.rootContext()->setContextProperty("features",&features);
        QQmlComponent component(&engine,QUrl::fromLocalFile(staging.path()+"/FeaturePage.qml"));
        std::unique_ptr<QObject> page(component.create()); QVERIFY2(page,qPrintable(component.errorString()));
        auto* item=qobject_cast<QQuickItem*>(page.get()); QVERIFY(item);
        QQuickWindow window; window.resize(1180,760); item->setParentItem(window.contentItem()); item->setSize(QSizeF(1180,760)); window.show();
        QTest::qWait(100);
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
    QGuiApplication app(argc,argv); FeatureQmlTests tests; return QTest::qExec(&tests,argc,argv);
}
#include "feature_qml_tests.moc"
