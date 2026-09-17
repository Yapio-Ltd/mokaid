#include <QDir>
#include <QFile>
#include <QFontDatabase>
#include <QGuiApplication>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QTemporaryDir>
#include <QtTest>
#include <memory>

// Exercise the rendered shared menu without a network, account or persisted
// workspace. This catches padding-only popups, not just successful QML loading.
class MenuView final {
public:
    QTemporaryDir directory;
    QQmlEngine engine;
    QStringList warnings;
    std::unique_ptr<QObject> root;
    QQuickWindow window;
    QString failure;

    MenuView() {
        for (const auto& name : QDir(QStringLiteral(MOKAID_MENU_QML_DIRECTORY)).entryList({"*.qml", "*.js"}, QDir::Files))
            QFile::copy(QStringLiteral(MOKAID_MENU_QML_DIRECTORY) + "/" + name, directory.path() + "/" + name);
        QFile qmldir(directory.path() + "/qmldir");
        if (!qmldir.open(QIODevice::WriteOnly)) { failure = "Could not write QML module"; return; }
        qmldir.write("singleton Theme 1.0 Theme.qml\n");
        qmldir.close();
        QObject::connect(&engine, &QQmlEngine::warnings, &engine, [this](const QList<QQmlError>& errors) {
            for (const auto& error : errors) warnings.append(error.toString());
        });
        QQmlComponent component(&engine);
        component.setData(R"QML(
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic as Basic
import QtQml.Models
Item {
    id: root
    width: 750; height: 580
    property string triggered: ""
    property var rows: [{id: "original"}]
    property var entries: [
        {id: "create", title: "Create task", enabled: true},
        {id: "offline", title: "Unavailable while offline", enabled: false},
        {id: "completed", title: "Show completed tasks", enabled: true, checkable: true}
    ]
    function replaceEntries() {
        entries = [{id: "replacement", title: "Transfer ownership to another workspace member", enabled: true}]
    }
    Basic.Button {
        id: anchor; objectName: "anchor"
        x: root.width - width - 12; y: root.height - height - 12
        width: 90; height: 38; text: "Actions"
        onClicked: menu.openFor(anchor)
    }
    ListView {
        x: 90; y: 80; width: 240; height: 120; clip: true
        model: root.rows
        delegate: Basic.Button {
            required property var modelData
            objectName: "row_" + modelData.id
            width: 200; height: 38; text: "Agent actions"
            onClicked: {
                menu.openFor(this)
                root.rows = [{id: "replacement"}]
            }
        }
    }
    MokaidMenu {
        id: menu; objectName: "menu"
        Instantiator {
            model: root.entries
            delegate: MokaidMenu.Entry {
                required property var modelData
                objectName: "entry_" + modelData.id
                text: modelData.title; enabled: modelData.enabled
                checkable: Boolean(modelData.checkable)
                onTriggered: root.triggered = modelData.id
            }
            onObjectAdded: function(index, object) { menu.insertItem(index, object) }
            onObjectRemoved: function(index, object) { menu.removeItem(object) }
        }
        MokaidMenu {
            id: submenu; objectName: "submenu"; title: "Advanced"
            MokaidMenu.Entry { objectName: "nested"; text: "Inspect task history"; onTriggered: root.triggered = "history" }
        }
    }
}
)QML", QUrl::fromLocalFile(directory.path() + "/MenuFixture.qml"));
        root.reset(component.create());
        failure = component.errorString();
        auto* item = qobject_cast<QQuickItem*>(root.get());
        if (!item) return;
        item->setParentItem(window.contentItem());
        window.resize(750, 580);
        window.show();
        window.requestActivate();
    }
    ~MenuView() {
        if (auto* item = qobject_cast<QQuickItem*>(root.get())) item->setParentItem(nullptr);
    }
    QObject* object(const char* name) const {
        if (!root) return nullptr;
        const auto target = QString::fromUtf8(name);
        if (auto* object = root->findChild<QObject*>(target)) return object;
        QList<QQuickItem*> items{window.contentItem()};
        for (qsizetype index = 0; index < items.size(); ++index) {
            if (items[index]->objectName() == target) return items[index];
            items.append(items[index]->childItems());
        }
        return nullptr;
    }
    QQuickItem* item(const char* name) const { return qobject_cast<QQuickItem*>(object(name)); }
    bool click(const char* name) {
        auto* control = item(name);
        if (!control || !control->isVisible()) return false;
        QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier,
                         control->mapToScene(QPointF(control->width() / 2, control->height() / 2)).toPoint());
        return true;
    }
    bool visible(const char* name = "menu") const { return object(name) && object(name)->property("visible").toBool(); }
    bool capture(const QString& name) {
        const auto output = qEnvironmentVariable("MOKAID_NATIVE_CAPTURE_DIR");
        if (output.isEmpty()) return true;
        QDir().mkpath(output);
        return window.grabWindow().save(output + "/" + name + ".png");
    }
};

class MenuQmlTests final : public QObject {
    Q_OBJECT
private slots:
    void rowMenuSurvivesSelectionReplacingItsDelegate() {
        MenuView view;
        QVERIFY2(view.root, qPrintable(view.failure));
        QTest::qWait(40);
        QVERIFY(view.click("row_original"));
        QTRY_VERIFY(view.visible());
        QTest::qWait(60); // The retired delegate is deleted after the click.
        auto* content = view.object("menu")->property("contentItem").value<QQuickItem*>();
        QVERIFY(content);
        QCOMPARE(content->window(), &view.window);
        QVERIFY(content->isVisible());
        QVERIFY(view.capture("menu-after-agent-selection"));
        QVERIFY(view.click("entry_create"));
        QTRY_COMPARE(view.root->property("triggered").toString(), QString("create"));
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }

    void readableMenuTracksLiveActionsAndStaysInsideWindow() {
        MenuView view;
        QVERIFY2(view.root, qPrintable(view.failure));
        QVERIFY(view.click("anchor"));
        QTRY_VERIFY(view.visible());
        auto* menu = view.object("menu");
        QCOMPARE(menu->property("count").toInt(), 4);
        QVERIFY(menu->property("width").toReal() >= 224);
        QTest::qWait(40);
        for (const auto* name : {"entry_create", "entry_offline", "entry_completed"}) {
            const auto* entry = view.item(name);
            QVERIFY(entry);
            QVERIFY(entry->isVisible());
            QVERIFY(entry->width() >= 200);
            QVERIFY(entry->height() >= 32);
            const auto origin = entry->mapToScene(QPointF());
            QVERIFY(origin.x() >= 0 && origin.y() >= 0);
            QVERIFY(origin.x() + entry->width() <= view.window.width());
            QVERIFY(origin.y() + entry->height() <= view.window.height());
            const auto* label = qobject_cast<QQuickItem*>(entry->property("contentItem").value<QObject*>());
            QVERIFY(label && label->width() > 150 && label->height() > 10);
            QVERIFY(!label->property("text").toString().isEmpty());
        }
        QVERIFY(view.capture("menu-actions"));
        QVERIFY(QMetaObject::invokeMethod(view.root.get(), "replaceEntries"));
        QTRY_COMPARE(menu->property("count").toInt(), 2);
        QTRY_VERIFY(view.item("entry_replacement"));
        QTRY_VERIFY(view.item("entry_replacement")->width() >= 300);
        QVERIFY(view.item("entry_replacement")->property("text").toString().contains("ownership"));
        QTest::keyClick(&view.window, Qt::Key_Escape);
        QTRY_VERIFY(!view.visible());
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }

    void pointerHonorsEnabledStateAndDispatchesTheChosenAction() {
        MenuView view;
        QVERIFY2(view.root, qPrintable(view.failure));
        QVERIFY(view.click("anchor"));
        QTRY_VERIFY(view.visible());
        QVERIFY(view.click("entry_offline"));
        QCOMPARE(view.root->property("triggered").toString(), QString());
        QVERIFY(view.visible());
        QVERIFY(view.click("entry_create"));
        QTRY_COMPARE(view.root->property("triggered").toString(), QString("create"));
        QTRY_VERIFY(!view.visible());
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }

    void keyboardSkipsDisabledActionsAndRestoresFocusOnEscape() {
        MenuView view;
        QVERIFY2(view.root, qPrintable(view.failure));
        QVERIFY(view.click("anchor"));
        QTRY_VERIFY(view.visible());
        QTest::keyClick(&view.window, Qt::Key_Down);
        QTRY_VERIFY(view.item("entry_create")->hasActiveFocus());
        QTest::keyClick(&view.window, Qt::Key_Down);
        QTRY_VERIFY(view.item("entry_completed")->hasActiveFocus());
        QTest::keyClick(&view.window, Qt::Key_Return);
        QTRY_COMPARE(view.root->property("triggered").toString(), QString("completed"));
        QVERIFY(view.item("entry_completed")->property("checked").toBool());
        QTRY_VERIFY(!view.visible());
        QVERIFY(view.click("anchor"));
        QTRY_VERIFY(view.visible());
        QTest::keyClick(&view.window, Qt::Key_Escape);
        QTRY_VERIFY(!view.visible());
        QTRY_VERIFY(view.item("anchor")->hasActiveFocus());
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }

    void submenusRemainKeyboardAccessible() {
        MenuView view;
        QVERIFY2(view.root, qPrintable(view.failure));
        QVERIFY(view.click("anchor"));
        QTRY_VERIFY(view.visible());
        for (int i = 0; i < 3; ++i) QTest::keyClick(&view.window, Qt::Key_Down);
        QTest::keyClick(&view.window, Qt::Key_Right);
        QTRY_VERIFY(view.visible("submenu"));
        QVERIFY(view.object("submenu")->property("width").toReal() >= 224);
        QTest::keyClick(&view.window, Qt::Key_Down);
        QTest::keyClick(&view.window, Qt::Key_Return);
        QTRY_COMPARE(view.root->property("triggered").toString(), QString("history"));
        QTRY_VERIFY(!view.visible());
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }
};

int main(int argc, char** argv) {
    qputenv("QT_QPA_PLATFORM", "offscreen");
    QQuickWindow::setGraphicsApi(QSGRendererInterface::Software);
    QQuickStyle::setStyle("Basic");
    QGuiApplication app(argc, argv);
    QFontDatabase::addApplicationFont(QStringLiteral(MOKAID_MENU_QML_DIRECTORY) + "/../assets/fonts/Manrope.ttf");
    MenuQmlTests tests;
    return QTest::qExec(&tests, argc, argv);
}
#include "menu_qml_tests.moc"
