#include <QDir>
#include <QFile>
#include <QFontDatabase>
#include <QGuiApplication>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQmlPropertyMap>
#include <QQuickItem>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QTemporaryDir>
#include <QtTest>
#include <memory>

// Isolated interface fixtures: no account, microphone, network or live missions.
class FakeOrchestrator final : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool ready MEMBER ready NOTIFY changed)
    Q_PROPERTY(bool busy MEMBER busy NOTIFY changed)
    Q_PROPERTY(bool refreshing MEMBER refreshing NOTIFY changed)
    Q_PROPERTY(QString draft MEMBER draft NOTIFY changed)
    Q_PROPERTY(QString language MEMBER language NOTIFY changed)
    Q_PROPERTY(QString error MEMBER error NOTIFY changed)
    Q_PROPERTY(QString pendingInstruction MEMBER pendingInstruction NOTIFY changed)
    Q_PROPERTY(QVariantList messages MEMBER messages NOTIFY changed)
    Q_PROPERTY(QVariantList missions MEMBER missions NOTIFY changed)
public:
    bool ready = true, busy = false, refreshing = false;
    QString draft, language = "fr", error, pendingInstruction;
    QVariantList messages, missions;
    int refreshCount = 0, sendCount = 0, prepareCount = 0;
    QString sentText, sentLanguage, reviewedId, canceledId;
    Q_INVOKABLE void refresh() { ++refreshCount; }
    Q_INVOKABLE void sendMessage(const QString& text, const QString& locale) {
        ++sendCount; sentText = text; sentLanguage = locale; draft.clear(); emit changed();
    }
    Q_INVOKABLE void prepareMission() { ++prepareCount; }
    Q_INVOKABLE void reviewMission(const QString& id) { reviewedId = id; }
    Q_INVOKABLE void cancelMission(const QString& id) { canceledId = id; }
    void reply(const QString& text, const QString& locale) { emit assistantReplied(text, locale); }
signals:
    void changed();
    void assistantReplied(const QString& text, const QString& language);
};

class FakeVoice final : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool ready MEMBER ready NOTIFY changed)
    Q_PROPERTY(QString state MEMBER state NOTIFY changed)
    Q_PROPERTY(QString error MEMBER error NOTIFY changed)
    Q_PROPERTY(double progress MEMBER progress NOTIFY changed)
    Q_PROPERTY(double level MEMBER level NOTIFY changed)
public:
    bool ready = true;
    QString state = "ready", error;
    double progress = 0, level = 0.45;
    int startCount = 0, stopCount = 0, cancelCount = 0, speakCount = 0, setupCount = 0;
    QString spokenText, spokenLanguage;
    Q_INVOKABLE void startListening() { ++startCount; state = "listening"; emit changed(); }
    Q_INVOKABLE void stopListening() { ++stopCount; state = "transcribing"; emit changed(); }
    Q_INVOKABLE void cancel() { ++cancelCount; state = "ready"; emit changed(); }
    Q_INVOKABLE void speak(const QString& text, const QString& locale) {
        ++speakCount; spokenText = text; spokenLanguage = locale; state = "speaking"; emit changed();
    }
    Q_INVOKABLE void setup() { ++setupCount; state = "preparing"; emit changed(); }
    void complete(const QString& text, const QString& locale) {
        state = "ready"; emit changed(); emit transcribed(text, locale);
    }
signals:
    void changed();
    void transcribed(const QString& text, const QString& language);
};

class OrchestratorView final {
public:
    QTemporaryDir directory;
    FakeOrchestrator controller;
    FakeVoice voice;
    std::unique_ptr<QQmlPropertyMap> system{QQmlPropertyMap::create()};
    QQmlEngine engine;
    QStringList warnings;
    std::unique_ptr<QObject> root;
    QQuickWindow window;
    QString failure;

    explicit OrchestratorView(QSize size = {1440, 900}) {
        const QString source = QStringLiteral(MOKAID_ORCHESTRATOR_QML_DIRECTORY);
        for (const auto* name : {"MokedDock.qml", "MokedMascot.qml", "MokaidDialog.qml", "MokaidIcon.qml", "MokaidIconButton.qml", "MokaidLabel.qml", "MokaidButton.qml", "MokaidTextArea.qml", "Theme.qml"}) {
            if (!QFile::copy(source + "/" + name, directory.path() + "/" + name)) {
                failure = QString("Could not stage %1").arg(name); return;
            }
        }
        QFile qmldir(directory.path() + "/qmldir");
        if (!qmldir.open(QIODevice::WriteOnly)) { failure = "Could not write QML module"; return; }
        qmldir.write("singleton Theme 1.0 Theme.qml\n"); qmldir.close();
        system->insert("reducedMotion", true);
        engine.rootContext()->setContextProperty("fixtureController", &controller);
        engine.rootContext()->setContextProperty("fixtureVoice", &voice);
        engine.rootContext()->setContextProperty("system", system.get());
        QObject::connect(&engine, &QQmlEngine::warnings, &engine, [this](const QList<QQmlError>& errors) {
            for (const auto& error : errors) warnings.append(error.toString());
        });
        QQmlComponent component(&engine);
        component.setData(R"QML(
import QtQuick
import QtQuick.Controls.Basic as Basic
Rectangle {
    id: root
    width: 1440; height: 900; color: Theme.background
    Rectangle {
        x: 18; y: 18; width: 196; height: parent.height - 36; radius: 18; color: Theme.surface
        Column {
            x: 22; y: 28; spacing: 26
            MokaidLabel { text: "Mokaid"; font.pixelSize: 26; font.bold: true }
            MokaidLabel { text: "Bureau"; color: Theme.secondary }
            MokaidLabel { text: "Agents"; color: Theme.secondary }
            MokaidLabel { text: "Missions"; color: Theme.secondary }
            MokaidLabel { text: "Livrables"; color: Theme.secondary }
        }
    }
    Column {
        x: 250; y: 52; spacing: 16
        MokaidLabel { text: "Espace de travail de démonstration"; font.pixelSize: 24; font.bold: true }
        MokaidLabel { text: "INTERFACE TEST · SYNTHETIC DATA"; color: Theme.muted; font.pixelSize: 11 }
        Basic.Button { objectName: "workspaceFocus"; text: "Action de test"; font.family: Theme.fontFamily }
    }
    MokedDock {
        objectName: "mokedDock"; anchors.fill: parent
        controller: fixtureController; voiceController: fixtureVoice
        signedIn: true; reducedMotion: true; animated: false
    }
}
)QML", QUrl::fromLocalFile(directory.path() + "/OrchestratorFixture.qml"));
        root.reset(component.create());
        failure = component.errorString();
        auto* item = qobject_cast<QQuickItem*>(root.get());
        if (!item) return;
        item->setParentItem(window.contentItem());
        resize(size);
        window.show(); window.requestActivate();
    }
    ~OrchestratorView() {
        if (auto* item = qobject_cast<QQuickItem*>(root.get())) item->setParentItem(nullptr);
    }
    void resize(QSize size) {
        window.resize(size);
        if (auto* item = qobject_cast<QQuickItem*>(root.get())) item->setSize(size);
    }
    QList<QQuickItem*> items() const {
        QList<QQuickItem*> result{window.contentItem()};
        for (qsizetype i = 0; i < result.size(); ++i) result.append(result[i]->childItems());
        return result;
    }
    QObject* object(const char* name) const {
        if (!root) return nullptr;
        if (auto* found = root->findChild<QObject*>(QString::fromUtf8(name))) return found;
        for (auto* item : items()) if (item->objectName() == QString::fromUtf8(name)) return item;
        return nullptr;
    }
    QQuickItem* item(const char* name) const { return qobject_cast<QQuickItem*>(object(name)); }
    QQuickItem* byProperty(const char* property, const QString& value) const {
        for (auto* item : items())
            if (item->isVisible() && item->property(property).toString() == value) return item;
        return nullptr;
    }
    bool click(QQuickItem* control) {
        if (!control || !control->isVisible() || !control->isEnabled() || control->width() <= 0 || control->height() <= 0) return false;
        QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier,
                         control->mapToScene(QPointF(control->width() / 2, control->height() / 2)).toPoint());
        return true;
    }
    bool click(const char* name) { return click(item(name)); }
    bool expanded() const { return object("mokedDock")->property("expanded").toBool(); }
    bool open() { return QMetaObject::invokeMethod(object("mokedDock"), "show"); }
    bool capture(const QString& name) {
        // Give layout and queued scroll-to-end a frame, with or without captures.
        QTest::qWait(100);
        const auto output = qEnvironmentVariable("MOKAID_ORCHESTRATOR_CAPTURE_DIR");
        if (output.isEmpty()) return true;
        QDir().mkpath(output);
        return window.grabWindow().save(output + "/" + name + ".png");
    }
    bool insidePanel(const char* name) const {
        const auto* child = item(name); const auto* panel = item("mokedPanel");
        if (!child || !panel) return false;
        const auto position = child->mapToItem(panel, QPointF{});
        return position.x() >= -1 && position.y() >= -1 && position.x() + child->width() <= panel->width() + 1 && position.y() + child->height() <= panel->height() + 1;
    }
    void populate() {
        controller.messages = {
            QVariantMap{{"role", "user"}, {"body", "Prépare une comparaison des offres reçues et confie la synthèse à un agent."}},
            QVariantMap{{"role", "assistant"}, {"body", "Je peux préparer une mission de comparaison. L’agent analysera les critères, documentera les différences et déposera une synthèse dans les livrables."}}
        };
        controller.pendingInstruction = "Comparer les offres et livrer une synthèse argumentée en français.";
        controller.missions = {
            QVariantMap{{"id", "synthetic-delivered"}, {"title", "Synthèse des offres · exemple"}, {"status", "completed"}, {"progress_percent", 100}, {"assigned_agent_name", "Camille · agent de démonstration"},
                        {"artifacts", QVariantList{QVariantMap{{"id", "synthetic-output"}, {"name", "synthese-exemple.pdf"}, {"source", "output"}}}}},
            QVariantMap{{"id", "synthetic-active"}, {"title", "Comparer les critères de sélection · exemple"}, {"status", "in_progress"}, {"progress_percent", 42}, {"assigned_agent_name", "Alex · agent de démonstration"}}
        };
        emit controller.changed();
    }
};

class OrchestratorQmlTests final : public QObject {
    Q_OBJECT
private slots:
    void collapsedOpenAndKeyboardClose() {
        OrchestratorView view;
        QVERIFY2(view.root, qPrintable(view.failure));
        QTest::qWait(60);
        QVERIFY(!view.expanded());
        QVERIFY(!view.item("mokedPanel")->isVisible());
        QVERIFY(view.capture("moked-collapsed-1440"));
        view.item("workspaceFocus")->forceActiveFocus();
        QVERIFY(view.click("mokedLauncher"));
        QTRY_VERIFY(view.expanded());
        QTRY_VERIFY(view.item("mokedComposer")->hasActiveFocus());
        QCOMPARE(view.controller.refreshCount, 1);
        QVERIFY(view.insidePanel("mokedComposer"));
        QVERIFY(view.capture("moked-empty-1440"));
        QTest::keyClick(&view.window, Qt::Key_Escape);
        QTRY_VERIFY(!view.expanded());
        QTRY_VERIFY(view.item("workspaceFocus")->hasActiveFocus());
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }

    void typingEnterAndOfflineDraft() {
        OrchestratorView view({1000, 680});
        QVERIFY2(view.root, qPrintable(view.failure));
        QVERIFY(view.open());
        QTRY_VERIFY(view.item("mokedComposer")->hasActiveFocus());
        for (char key : QByteArray("Prepare a summary")) QTest::keyClick(&view.window, key);
        QTRY_COMPARE(view.controller.draft, QString("Prepare a summary"));
        QVERIFY(view.item("mokedSend")->isEnabled());
        QTest::keyClick(&view.window, Qt::Key_Return, Qt::ShiftModifier);
        QTRY_VERIFY(view.controller.draft.contains('\n'));
        QCOMPARE(view.controller.sendCount, 0);
        QTest::keyClick(&view.window, Qt::Key_Return);
        QCOMPARE(view.controller.sendCount, 1);
        QCOMPARE(view.controller.sentText, QString("Prepare a summary\n"));
        QCOMPARE(view.controller.sentLanguage, QString("fr"));
        QTRY_VERIFY(view.controller.draft.isEmpty());
        view.controller.ready = false;
        view.controller.draft = "Brouillon conservé hors ligne";
        emit view.controller.changed();
        QTRY_VERIFY(!view.item("mokedSend")->isEnabled());
        QTest::keyClick(&view.window, Qt::Key_Return);
        QCOMPARE(view.controller.sendCount, 1);
        QCOMPARE(view.controller.draft, QString("Brouillon conservé hors ligne"));
        QVERIFY(view.insidePanel("mokedComposer"));
        QVERIFY(view.insidePanel("mokedSend"));
        QVERIFY(view.capture("moked-offline-1000"));
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }

    void proposalAndDeliveryRoutes() {
        OrchestratorView view;
        QVERIFY2(view.root, qPrintable(view.failure));
        view.populate(); QVERIFY(view.open()); QTest::qWait(80);
        QCOMPARE(view.object("mokedDock")->property("activeMissions").toInt(), 1);
        QVERIFY(view.capture("moked-populated-1440"));
        const auto* prepare = view.item("mokedPrepareMission");
        QVERIFY(prepare);
        QTest::mouseMove(&view.window, prepare->mapToScene(QPointF{prepare->width() / 2, prepare->height() / 2}).toPoint());
        QTRY_VERIFY(prepare->property("hovered").toBool());
        QVERIFY(view.capture("moked-mission-hover-1440"));
        QVERIFY(view.click("mokedPrepareMission"));
        QCOMPARE(view.controller.prepareCount, 1);
        QVERIFY(!view.expanded());
        QVERIFY(view.open());
        QVERIFY(view.click("mokedMissionsTab"));
        QTRY_COMPARE(view.object("mokedDock")->property("currentTab").toInt(), 1);
        QTest::qWait(60);
        QVERIFY(view.capture("moked-missions-1440"));
        QVERIFY(view.click(view.byProperty("text", "Voir le livrable")));
        QCOMPARE(view.controller.reviewedId, QString("synthetic-delivered"));
        QVERIFY(!view.expanded());
        view.resize({1000, 680}); QVERIFY(view.open());
        QVERIFY(view.click("mokedChatTab")); QTest::qWait(60);
        QVERIFY(view.insidePanel("mokedPrepareMission"));
        QVERIFY(view.insidePanel("mokedSend"));
        QVERIFY(view.capture("moked-populated-1000"));
        const auto* messages = view.item("mokedMessages");
        QVERIFY(messages->property("contentY").toReal() + messages->height() >= messages->property("contentHeight").toReal() - 1);
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }

    void dictationOnlyInsertsDraftAndKeepsDetectedLanguage() {
        OrchestratorView view({1000, 680});
        QVERIFY2(view.root, qPrintable(view.failure));
        view.controller.draft = "Contexte existant."; emit view.controller.changed();
        QVERIFY(view.open()); QTest::qWait(50);
        QVERIFY(view.click("mokedMicrophone"));
        QCOMPARE(view.voice.startCount, 1);
        QCOMPARE(view.voice.state, QString("listening"));
        QVERIFY(!view.item("mokedComposer")->isEnabled());
        QVERIFY(!view.item("mokedSend")->isEnabled());
        QVERIFY(view.capture("moked-listening-1000"));
        const auto* finish = view.byProperty("text", "Terminer et transcrire");
        QVERIFY(finish);
        const auto finishBottom = finish->mapToItem(view.item("mokedPanel"), QPointF{0, finish->height()}).y();
        if (view.item("mokedComposer")->isVisible())
            QVERIFY(finishBottom <= view.item("mokedComposer")->mapToItem(view.item("mokedPanel"), QPointF{}).y());
        QVERIFY(view.click(view.byProperty("text", "Terminer et transcrire")));
        QCOMPARE(view.voice.stopCount, 1);
        QCOMPARE(view.voice.state, QString("transcribing"));
        QVERIFY(view.capture("moked-transcribing-1000"));
        view.voice.complete(QString::fromUtf8("שלום, אפשר להכין סיכום?"), "he");
        QTRY_COMPARE(view.controller.draft, QString::fromUtf8("Contexte existant.\nשלום, אפשר להכין סיכום?"));
        QCOMPARE(view.controller.language, QString("he"));
        QCOMPARE(view.controller.sendCount, 0);
        QTRY_VERIFY(view.item("mokedComposer")->hasActiveFocus());
        QVERIFY(view.click("mokedSend"));
        QCOMPARE(view.controller.sendCount, 1);
        QCOMPARE(view.controller.sentLanguage, QString("he"));
        QVERIFY(view.click("mokedMicrophone"));
        QVERIFY(view.click("mokedClose"));
        view.voice.complete("late canceled transcript", "en");
        QVERIFY(view.controller.draft.isEmpty());
        QCOMPARE(view.controller.sendCount, 1);
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }

    void completedMissionWithoutOutputDoesNotClaimDelivery() {
        OrchestratorView view;
        QVERIFY2(view.root, qPrintable(view.failure));
        view.controller.missions = {
            QVariantMap{{"id", "synthetic-completed-no-output"}, {"title", "Vérification terminée sans fichier"},
                        {"status", "completed"}, {"progress_percent", 100}, {"artifacts", QVariantList{}}}
        };
        emit view.controller.changed();
        QVERIFY(view.open());
        QVERIFY(view.click("mokedMissionsTab"));
        QTRY_VERIFY(view.byProperty("text", "Terminée"));
        QVERIFY(!view.byProperty("text", "Voir le livrable"));
        QVERIFY(view.click(view.byProperty("text", "Voir la mission")));
        QCOMPARE(view.controller.reviewedId, QString("synthetic-completed-no-output"));
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }

    void voicePlaybackCanBeEnabledAndInterrupted() {
        OrchestratorView view;
        QVERIFY2(view.root, qPrintable(view.failure));
        QVERIFY(view.open()); QTest::qWait(50);
        QVERIFY(view.click(view.byProperty("hint", "Lire les réponses à voix haute")));
        QVERIFY(view.object("mokedDock")->property("voiceEnabled").toBool());
        view.controller.reply("Your mission is ready to review.", "en");
        QCOMPARE(view.voice.speakCount, 1);
        QCOMPARE(view.voice.spokenLanguage, QString("en"));
        QVERIFY(view.capture("moked-speaking-1440"));
        QVERIFY(view.click(view.byProperty("text", "Arrêter")));
        QTest::qWait(30);
        QVERIFY(view.click(view.byProperty("hint", "Désactiver les réponses vocales")));
        QVERIFY(!view.object("mokedDock")->property("voiceEnabled").toBool());
        QCOMPARE(view.voice.state, QString("ready"));
        view.controller.reply("Une deuxième réponse.", "fr");
        QCOMPARE(view.voice.speakCount, 1);
        QVERIFY(view.click("mokedClose"));
        view.controller.reply("Le livrable est disponible.", "fr");
        QCOMPARE(view.object("mokedDock")->property("unread").toInt(), 1);
        QVERIFY(view.capture("moked-notification-1440"));
        QVERIFY(view.open());
        QCOMPARE(view.object("mokedDock")->property("unread").toInt(), 0);
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }

    void microphoneSetupAndSignedOutState() {
        OrchestratorView view({1000, 680});
        QVERIFY2(view.root, qPrintable(view.failure));
        view.voice.ready = false; emit view.voice.changed();
        QVERIFY(view.open()); QTest::qWait(60);
        QVERIFY(view.click("mokedMicrophone"));
        QTRY_VERIFY(view.object("mokedVoiceSettings")->property("visible").toBool());
        QCOMPARE(view.voice.startCount, 0);
        QVERIFY(view.capture("moked-voice-setup-1000"));
        QVERIFY(view.click(view.byProperty("text", "Vérifier les modèles locaux")));
        QCOMPARE(view.voice.setupCount, 1);
        QVERIFY(QMetaObject::invokeMethod(view.object("mokedVoiceSettings"), "close"));
        view.object("mokedDock")->setProperty("signedIn", false);
        QVERIFY(!view.expanded());
        QVERIFY(view.open()); QTest::qWait(50);
        QVERIFY(!view.item("mokedComposer")->isEnabled());
        QVERIFY(!view.item("mokedMicrophone")->isEnabled());
        QVERIFY(view.capture("moked-signed-out-1000"));
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }
};

int main(int argc, char** argv) {
    qputenv("QT_QPA_PLATFORM", "offscreen");
    QQuickWindow::setGraphicsApi(QSGRendererInterface::Software);
    QQuickStyle::setStyle("Basic");
    QGuiApplication app(argc, argv);
    QFontDatabase::addApplicationFont(QStringLiteral(MOKAID_ORCHESTRATOR_QML_DIRECTORY) + "/../assets/fonts/Manrope.ttf");
    OrchestratorQmlTests tests;
    return QTest::qExec(&tests, argc, argv);
}
#include "orchestrator_qml_tests.moc"
