#include "native_viewport.hpp"
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
#include <algorithm>
#include <cstdio>
#include <memory>

namespace {
void tourProgress(const char* stage) {
    static QElapsedTimer elapsed;
    if (!elapsed.isValid()) elapsed.start();
    std::fprintf(stdout, "[office-tour +%lldms] %s\n", static_cast<long long>(elapsed.elapsed()), stage);
    std::fflush(stdout);
}
}

// This executable loads the production office QML and native GPU viewport. Its
// synthetic roster and replies are confined to this test executable; it never
// signs in, reads an account cache, or calls a production API.
class TourOfficeFixture final : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList agents MEMBER agents NOTIFY changed)
    Q_PROPERTY(QVariantMap selectedAgent MEMBER selectedAgent NOTIFY changed)
    Q_PROPERTY(QVariantList messages MEMBER messages NOTIFY changed)
    Q_PROPERTY(QVariantList conversations MEMBER conversations NOTIFY changed)
    Q_PROPERTY(QString conversationId MEMBER conversationId NOTIFY changed)
    Q_PROPERTY(QString draft MEMBER draft NOTIFY changed)
    Q_PROPERTY(QString stream MEMBER stream NOTIFY changed)
    Q_PROPERTY(QString error MEMBER error NOTIFY changed)
    Q_PROPERTY(bool loading MEMBER loading NOTIFY changed)
    Q_PROPERTY(bool sending MEMBER sending NOTIFY changed)
public:
    QVariantList agents, messages, conversations;
    QVariantMap selectedAgent;
    QString conversationId, draft, stream, error, submittedBody, submittedAgent;
    QHash<QString, QString> drafts;
    int sendCount{};
    bool loading{}, sending{};

    TourOfficeFixture() {
        const QStringList names{"Alex", "Robin", "Morgan", "Sam", "Taylor", "Jamie", "Casey", "Avery", "Jordan"};
        const QStringList assets{"male", "developer", "research", "design", "finance", "legal", "byte", "nyx", "moss"};
        for (int i = 0; i < names.size(); ++i)
            agents.append(QVariantMap{{"id", QString("tour-fixture-%1").arg(i)},
                {"display_name", names[i] + " · test"}, {"name", names[i] + " · test"},
                {"role_title", "Synthetic teammate"}, {"kind", "ai"}, {"status", "working"},
                {"asset_type", assets[i]}, {"seat_index", i}, {"level", i + 1},
                {"current_task_id", QString("fixture-task-%1").arg(i)}, {"screen_connection", "live"},
                {"screen_task", QVariantMap{{"title", QString("Review the launch brief · test %1").arg(i + 1)},
                    {"status", "in_progress"}, {"progress_percent", 28 + i * 7},
                    {"latest_run", QVariantMap{{"id", QString("fixture-run-%1").arg(i)}, {"status", "running"},
                        {"tool_activity", QVariantList{
                            QVariantMap{{"description", "Reading the project brief · test"}, {"status", "ok"}},
                            QVariantMap{{"description", "Checking the mobile layout · test"}, {"status", "running"}}}}}}}}});
    }
    Q_INVOKABLE void selectAgent(const QString& id) {
        for (const auto& value : agents) {
            if (value.toMap().value("id").toString() != id) continue;
            if (!selectedAgent.isEmpty()) drafts[selectedAgent.value("id").toString()] = draft;
            selectedAgent = value.toMap(); draft = drafts.value(id); messages.clear();
            emit changed(); return;
        }
    }
    Q_INVOKABLE void closeChat() {
        drafts[selectedAgent.value("id").toString()] = draft;
        selectedAgent.clear(); draft.clear(); messages.clear(); emit changed();
    }
    Q_INVOKABLE void selectConversation(const QString& id) { conversationId = id; emit changed(); }
    Q_INVOKABLE void newConversation() { messages.clear(); conversationId.clear(); emit changed(); }
    Q_INVOKABLE void send(const QVariantList&) {
        if (sending || selectedAgent.isEmpty() || draft.trimmed().isEmpty()) return;
        ++sendCount; submittedBody = draft; submittedAgent = selectedAgent.value("id").toString();
        messages.append(QVariantMap{{"author_kind", "member"}, {"body", draft}});
        draft.clear(); sending = true; emit changed();
        const auto recipient = submittedAgent;
        QTimer::singleShot(50, this, [this, recipient] {
            if (selectedAgent.value("id").toString() != recipient) return;
            messages.append(QVariantMap{{"author_kind", "agent"},
                {"body", "Test reply: I am reviewing the synthetic task."}});
            sending = false; emit changed();
        });
    }
signals:
    void changed();
};

class TourAuxiliaryFixture final : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool hasDraft READ hasDraft CONSTANT)
    Q_PROPERTY(bool opened READ opened CONSTANT)
public:
    bool hasDraft() const { return false; }
    bool opened() const { return false; }
    Q_INVOKABLE void begin() {}
    Q_INVOKABLE void beginForAgent(const QString&, const QString&) {}
    Q_INVOKABLE void beginForAgent(const QString&) {}
    Q_INVOKABLE void addFiles(const QVariantList&) {}
    Q_INVOKABLE void navigate(const QString&) {}
    Q_INVOKABLE void openRecord(const QString&, const QString&) {}
    Q_INVOKABLE void openMarketplaceOffer(const QString&, const QString&) {}
    Q_INVOKABLE QVariantMap describe(const QVariantMap&) const { return {{"kind", "document"}}; }
    Q_INVOKABLE void openCollection(const QVariantList&, int) {}
signals:
    void changed();
};

class TourFeatureFixture final : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString currentPage MEMBER currentPage NOTIFY changed)
    Q_PROPERTY(QString selectedId MEMBER selectedId NOTIFY changed)
    Q_PROPERTY(QVariantMap selectedRecord MEMBER selectedRecord NOTIFY changed)
    Q_PROPERTY(QVariantList selectedAgentTasks MEMBER selectedAgentTasks NOTIFY changed)
    Q_PROPERTY(QString selectedAgentTasksState MEMBER selectedAgentTasksState NOTIFY changed)
    Q_PROPERTY(QVariantList selectedAgentKnowledge MEMBER selectedAgentKnowledge NOTIFY changed)
    Q_PROPERTY(QString selectedAgentKnowledgeState MEMBER selectedAgentKnowledgeState NOTIFY changed)
    Q_PROPERTY(QVariantList actions MEMBER actions NOTIFY changed)
    Q_PROPERTY(bool busy MEMBER busy NOTIFY changed)
    Q_PROPERTY(bool offline MEMBER offline NOTIFY changed)
    Q_PROPERTY(QString error MEMBER error NOTIFY changed)
public:
    explicit TourFeatureFixture(TourOfficeFixture& roster) : office(roster) {}
    TourOfficeFixture& office;
    QString currentPage{"office"}, selectedId, selectedAgentTasksState{"idle"}, selectedAgentKnowledgeState{"idle"}, error;
    QVariantMap selectedRecord;
    QVariantList selectedAgentTasks, selectedAgentKnowledge, actions;
    bool busy{}, offline{};
    int selectCount{};
    Q_INVOKABLE void select(const QString& id) {
        ++selectCount;
        for (const auto& value : office.agents) {
            const auto agent=value.toMap();
            if (agent.value("id").toString()!=id) continue;
            selectedId=id; selectedRecord=agent;
            auto task=agent.value("screen_task").toMap();
            task.insert("id",agent.value("current_task_id")); task.insert("assigned_agent_id",id);
            selectedAgentTasks={task}; selectedAgentTasksState="ready";
            selectedAgentKnowledge.clear(); selectedAgentKnowledgeState="ready";
            emit changed(); return;
        }
        clearSelection();
    }
    Q_INVOKABLE void clearSelection() {
        selectedId.clear(); selectedRecord.clear(); selectedAgentTasks.clear(); selectedAgentKnowledge.clear();
        selectedAgentTasksState="idle"; selectedAgentKnowledgeState="idle"; emit changed();
    }
    Q_INVOKABLE void refresh() { if (!selectedId.isEmpty()) select(selectedId); }
    Q_INVOKABLE void navigate(const QString& page) { currentPage=page; clearSelection(); }
    Q_INVOKABLE void openRecord(const QString& page,const QString& id) { currentPage=page; selectedId=id; emit changed(); }
    Q_INVOKABLE void openMarketplaceOffer(const QString&,const QString&) { navigate("marketplace"); }
    Q_INVOKABLE QString actionContext(const QString& action) const { return currentPage+":"+selectedId+":"+action; }
    Q_INVOKABLE void submit(const QString&,const QVariantMap&) {}
signals:
    void changed();
    void actionSucceeded(QString context);
    void actionResult(QString actionId,QVariantMap result);
};

class OfficeTourView final {
public:
    QTemporaryDir staging;
    TourOfficeFixture office;
    TourAuxiliaryFixture auxiliary;
    TourFeatureFixture features{office};
    std::unique_ptr<QQmlPropertyMap> session{QQmlPropertyMap::create()};
    std::unique_ptr<QQmlPropertyMap> system{QQmlPropertyMap::create()};
    QQmlEngine engine;
    QStringList warnings;
    std::unique_ptr<QObject> root;
    QQuickWindow window;
    QQuickItem* item{};
    mokaid::NativeViewport* viewport{};
    QString failure;

    OfficeTourView() {
        tourProgress("constructing production QML fixture");
        const auto source = QStringLiteral(MOKAID_OFFICE_QML_DIRECTORY);
        for (const auto& name : QDir(source).entryList({"*.qml", "*.js"}, QDir::Files))
            QFile::copy(source + "/" + name, staging.path() + "/" + name);
        QFile qmldir(staging.path() + "/qmldir");
        if (!qmldir.open(QIODevice::WriteOnly)) { failure = "Could not stage production QML"; return; }
        qmldir.write("singleton Theme 1.0 Theme.qml\n"); qmldir.close();
        session->insert("online", true); session->insert("workspaceId", "tour-fixture-workspace");
        system->insert("reducedMotion", true); system->insert("quality", "auto");
        system->insert("assetRoot", qEnvironmentVariable("MOKAID_OFFICE_ASSETS", QStringLiteral(MOKAID_OFFICE_ASSET_DIRECTORY)));
        engine.rootContext()->setContextProperty("office", &office);
        engine.rootContext()->setContextProperty("session", session.get());
        engine.rootContext()->setContextProperty("system", system.get());
        engine.rootContext()->setContextProperty("features", &features);
        for (const auto* name : {"missions", "preview"})
            engine.rootContext()->setContextProperty(name, &auxiliary);
        QObject::connect(&engine, &QQmlEngine::warnings, &engine, [this](const QList<QQmlError>& errors) {
            for (const auto& error : errors) warnings.append(error.toString());
        });
        QQmlComponent component(&engine);
        component.setData(R"QML(
import QtQuick
Rectangle {
    color: "#090a11"
    OfficePage { objectName: "officePageUnderTest"; anchors.fill: parent; anchors.margins: 20; anchors.bottomMargin: 40 }
    Text {
        anchors.bottom: parent.bottom; anchors.bottomMargin: 10; anchors.horizontalCenter: parent.horizontalCenter
        text: "INTERFACE TEST · SYNTHETIC AGENTS AND REPLIES"; color: "#b3bcde"; font.pixelSize: 10
    }
}
)QML", QUrl::fromLocalFile(staging.path() + "/OfficeTourFixture.qml"));
        root.reset(component.create()); failure = component.errorString();
        item = qobject_cast<QQuickItem*>(root.get());
        if (!item) return;
        item->setParentItem(window.contentItem());
        QObject::connect(&window,&QWindow::widthChanged,&window,[this] { if (item) item->setSize(window.size()); });
        QObject::connect(&window,&QWindow::heightChanged,&window,[this] { if (item) item->setSize(window.size()); });
        viewport = root->findChild<mokaid::NativeViewport*>("officeViewport");
        resize(1440, 900);
        window.setTitle("Office tour interface test — synthetic agents");
        window.show(); window.requestActivate();
        tourProgress("native window shown");
    }
    ~OfficeTourView() {
        tourProgress("releasing native fixture");
        if (viewport) viewport->setPaused(true);
        if (item) item->setParentItem(nullptr);
        root.reset();
        window.releaseResources();
        tourProgress("native fixture released");
    }
    void resize(int width, int height) { window.resize(width, height); if (item) item->setSize(window.size()); }
    QList<QQuickItem*> children() const {
        QList<QQuickItem*> result;
        if (item) result.append(item);
        for (qsizetype i = 0; i < result.size(); ++i) result.append(result[i]->childItems());
        return result;
    }
    QQuickItem* find(const QString& name) const {
        for (auto* child : children()) if (child->objectName() == name && child->isVisible()) return child;
        return nullptr;
    }
    bool inside(const QQuickItem* control) const {
        if (!control || !control->isVisible() || control->width() < 1 || control->height() < 1) return false;
        const auto p = control->mapToScene({});
        return p.x() >= -1 && p.y() >= -1 && p.x() + control->width() <= window.width() + 1
            && p.y() + control->height() <= window.height() + 1;
    }
    bool insideOffice(const QQuickItem* control) const {
        const auto* page = find("officePageUnderTest");
        if (!page || !inside(control)) return false;
        const auto p = control->mapToItem(page, QPointF{});
        return p.x() >= -1 && p.y() >= -1 && p.x() + control->width() <= page->width() + 1
            && p.y() + control->height() <= page->height() + 1;
    }
    QString bounds(const QString& name) const {
        const auto* control=find(name);
        const auto* page=find("officePageUnderTest");
        if (!control || !page) return name+" is not visible";
        const auto p=control->mapToItem(page,QPointF{});
        return QString("%1: x=%2 y=%3 size=%4x%5; page=%6x%7; window=%8x%9")
            .arg(name).arg(p.x()).arg(p.y()).arg(control->width()).arg(control->height())
            .arg(page->width()).arg(page->height()).arg(window.width()).arg(window.height());
    }
    bool click(QQuickItem* control) {
        if (!inside(control) || !control->isEnabled()) return false;
        QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier,
            control->mapToScene({control->width() / 2, control->height() / 2}).toPoint());
        return true;
    }
    bool click(const QString& name) { return click(find(name)); }
    bool capture(const QString& name) {
        const auto output = qEnvironmentVariable("MOKAID_OFFICE_CAPTURE_DIR");
        if (output.isEmpty()) return true;
        QDir().mkpath(output);
        const auto image = window.grabWindow();
        return !image.isNull() && image.save(output + "/" + name + ".png");
    }
    QQuickItem* visibleAgentBadge() const {
        for (auto* child : children()) {
            if (!inside(child) || !child->isEnabled() || !child->parentItem()) continue;
            if (child->parentItem()->property("agentId").toString().isEmpty()) continue;
            if (child->metaObject()->indexOfSignal("clicked()") >= 0) return child;
        }
        return nullptr;
    }
};

class OfficeTourQmlTests final : public QObject {
    Q_OBJECT
private slots:
    void capturesAllStockCharactersFaceToFace() {
        const auto output = qEnvironmentVariable("MOKAID_CHARACTER_CAPTURE_DIR");
        if (output.isEmpty()) QSKIP("Opt-in native character evidence requires MOKAID_CHARACTER_CAPTURE_DIR");
        const auto assets = qEnvironmentVariable("MOKAID_OFFICE_ASSETS", QStringLiteral(MOKAID_OFFICE_ASSET_DIRECTORY));
        if (!QFile::exists(assets + "/manifest.json")) QSKIP("Cooked native office assets are required");
        QVERIFY(QDir().mkpath(output));
        QElapsedTimer elapsed; elapsed.start();
        OfficeTourView view;
        QVERIFY2(view.item, qPrintable(view.failure)); QVERIFY(view.viewport);
        QVERIFY(QTest::qWaitForWindowExposed(&view.window));
        QTRY_VERIFY_WITH_TIMEOUT(!view.viewport->loading(), 30000);
        QVERIFY2(view.viewport->error().isEmpty(), qPrintable(view.viewport->error()));
        QTRY_VERIFY_WITH_TIMEOUT(view.viewport->diagnostics().value("triangles").toInt() > 0, 15000);
        QVERIFY(view.viewport->reducedMotion());
        QVERIFY(view.click("officeEnter"));
        QTRY_VERIFY(view.viewport->immersive());
        auto* page = view.find("officePageUnderTest"); QVERIFY(page);
        const auto capture = [&](const QString& name) {
            const auto image = view.window.grabWindow();
            return !image.isNull() && image.save(output + "/character-" + name + ".png");
        };
        const auto visiblyChatting = [&](const QString& id) {
            const auto* model = view.viewport->actorIndicators();
            const auto roles = model->roleNames();
            for (int row = 0; row < model->rowCount(); ++row) {
                const auto index = model->index(row, 0);
                if (model->data(index, roles.key("agentId")).toString() != id) continue;
                return model->data(index, roles.key("onScreen")).toBool()
                    && model->data(index, roles.key("activityText")).toString()
                        == mokaid::AgentIndicatorModel::activityText("talking");
            }
            return false;
        };
        // Visit the nine real desk stops through OfficePage's production
        // approach-and-chat flow. Then replace two fixture assets to cover the
        // corporate and female catalog variants in the same real GPU scene.
        const QList<int> seats{5, 4, 3, 2, 1, 0, 8, 7, 6, 0, 1};
        constexpr qint64 captureBudgetMs = 240000;
        int captures = 0;
        for (int visit = 0; visit < seats.size(); ++visit) {
            view.window.requestActivate();
            // macOS may leave a CLI-launched capture window inactive while
            // the user works in another app. Rendering does not require focus.
            const int seat = seats[visit];
            if (visit >= 9) {
                auto agent = view.office.agents[seat].toMap();
                agent["asset_type"] = visit == 9 ? "corporate" : "female";
                view.office.agents[seat] = agent;
                emit view.office.changed();
                QTRY_COMPARE(view.viewport->agents()[seat].toMap().value("asset_type"), agent.value("asset_type"));
            }
            const auto agent = view.office.agents[seat].toMap();
            const auto id = agent.value("id").toString(), asset = agent.value("asset_type").toString();
            const auto stop = QString("desk_%1").arg(seat);
            QVERIFY2(elapsed.elapsed() < captureBudgetMs, "All character captures must finish in four minutes");
            QVERIFY(QMetaObject::invokeMethod(page, "selectAgent", Q_ARG(QVariant, QVariant(id))));
            const int remaining = static_cast<int>(std::clamp<qint64>(captureBudgetMs - elapsed.elapsed(), 0, 45000));
            int focusRetries = 0;
            const bool approached = QTest::qWaitFor([&] {
                if (view.office.selectedAgent.value("id").toString() == id) return true;
                // The separate navigation test verifies focus cancellation.
                // For visual evidence, resume up to two interrupted visits.
                if (focusRetries < 2 && page->property("approachingAgentId").toString().isEmpty()
                    && !view.viewport->tourMoving() && !view.viewport->tourSettling()) {
                    ++focusRetries;
                    QMetaObject::invokeMethod(page, "selectAgent", Q_ARG(QVariant, QVariant(id)));
                }
                return false;
            }, remaining);
            if (!approached) {
                capture(asset + "-approach-failed");
                const QString diagnostic = QStringList{
                    "Approach timed out", "asset=" + asset, "requested=" + id,
                    "selected=" + view.office.selectedAgent.value("id").toString(),
                    "pendingAgent=" + page->property("approachingAgentId").toString(),
                    "pendingStop=" + page->property("approachingStopId").toString(),
                    "currentStop=" + view.viewport->tourCurrentStop(),
                    "destination=" + view.viewport->tourDestination(),
                    "moving=" + QString::number(view.viewport->tourMoving()),
                    "settling=" + QString::number(view.viewport->tourSettling()),
                    "progress=" + QString::number(view.viewport->tourProgress()),
                    "active=" + QString::number(view.window.isActive()),
                    "paused=" + QString::number(view.viewport->paused()),
                    "elapsedMs=" + QString::number(elapsed.elapsed()),
                    "rendererError=" + view.viewport->error()
                }.join("; ");
                QFAIL(qPrintable(diagnostic));
            }
            QCOMPARE(view.viewport->tourCurrentStop(), stop);
            QVERIFY(!view.viewport->tourMoving()); QVERIFY(!view.viewport->tourSettling());
            QTRY_VERIFY_WITH_TIMEOUT(visiblyChatting(id), 3000);
            QVERIFY(view.inside(view.find("officeImmersiveChat")));
            QTest::qWait(600); // Settle the seated crossfade before recording the face and hands.
            QVERIFY2(capture(asset + "-chat"), qPrintable(asset));
            ++captures;
            QVERIFY2(view.viewport->error().isEmpty(), qPrintable(view.viewport->error()));
            QVERIFY2(view.viewport->avatarError().isEmpty(), qPrintable(view.viewport->avatarError()));
            if (asset == "legal") {
                // The same camera with gaze removed distinguishes a surface
                // defect from a conversation-pose defect without changing assets.
                view.office.closeChat();
                QTRY_VERIFY(view.viewport->conversationAgentId().isEmpty());
                QTest::qWait(600);
                QVERIFY(capture("legal-resting"));
            }
        }
        QCOMPARE(captures, 11);
        QCOMPARE(view.office.sendCount, 0);
        QVERIFY(view.office.messages.isEmpty());
        QVERIFY2(elapsed.elapsed() < captureBudgetMs, "All character captures must finish in four minutes");
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }
    void generatedMeshyCharactersRenderAtOfficeScale() {
        const auto directory=qEnvironmentVariable("MOKAID_GENERATED_CHARACTER_FIXTURES");
        if (directory.isEmpty()) QSKIP("Opt-in visual evidence requires completed Meshy output files");
        OfficeTourView view;
        QVERIFY2(view.item,qPrintable(view.failure)); QVERIFY(view.viewport);
        QVERIFY(QTest::qWaitForWindowExposed(&view.window));
        QTRY_VERIFY_WITH_TIMEOUT(!view.viewport->loading(),30000);
        QVERIFY2(view.viewport->error().isEmpty(),qPrintable(view.viewport->error()));
        const QVariantList agents{
            QVariantMap{{"id","meshy-text-fixture"},{"name","Prompt · actual Meshy output"},{"display_name","Prompt · Meshy"},{"kind","ai"},{"avatar_asset_id","mesh-text-fixture"},{"status","idle"},{"asset_type","custom:meshy-text-fixture"},{"seat_index",0}},
            QVariantMap{{"id","meshy-image-fixture"},{"name","Photo · actual Meshy output"},{"display_name","Photo · Meshy"},{"kind","ai"},{"avatar_asset_id","mesh-photo-fixture"},{"status","idle"},{"asset_type","custom:meshy-image-fixture"},{"seat_index",1}}};
        view.office.agents=agents; emit view.office.changed();
        view.viewport->setAgents(agents);
        auto* loader=view.viewport->findChild<mokaid::CustomAvatarLoader*>(); QVERIFY(loader);
        // Isolate network from GPU evidence: inject the exact completed cooker
        // output through the loader completion signal used by production.
        // No source substitution in catalog assets, account access or paid generation.
        loader->ready("custom:meshy-text-fixture",mokaid::engine::loadScene((directory+"/text.mokaidasset").toStdString()));
        loader->ready("custom:meshy-image-fixture",mokaid::engine::loadScene((directory+"/image.mokaidasset").toStdString()));
        QTRY_VERIFY_WITH_TIMEOUT(view.viewport->diagnostics().value("triangles").toInt()>0,15000);
        QTest::qWait(300);
        QVERIFY(view.capture("meshy-generated-office-overview"));
        QVERIFY(view.viewport->error().isEmpty()); QVERIFY(view.viewport->avatarError().isEmpty());
    }
    void entersFollowsPathsLooksAroundChatsAndReturns() {
        tourProgress("starting interactive tour scenario");
        const auto assets = qEnvironmentVariable("MOKAID_OFFICE_ASSETS", QStringLiteral(MOKAID_OFFICE_ASSET_DIRECTORY));
        if (!QFile::exists(assets + "/manifest.json")) QSKIP("Cooked native office assets are required for the real-renderer tour test");
        OfficeTourView view;
        QVERIFY2(view.item, qPrintable(view.failure));
        QVERIFY2(view.viewport, "OfficePage must expose the production officeViewport object");
        QVERIFY(QTest::qWaitForWindowExposed(&view.window));
        QTRY_VERIFY_WITH_TIMEOUT(!view.viewport->loading(), 30000);
        tourProgress("office assets loaded");
        QVERIFY2(view.viewport->error().isEmpty(), qPrintable(view.viewport->error()));
        // Synchronize the first loaded scene even when a CLI-launched native
        // window is occluded by another application on the test machine.
        QVERIFY(!view.window.grabWindow().isNull());
        tourProgress("initial GPU frame synchronized");
        QTRY_VERIFY2_WITH_TIMEOUT(view.viewport->diagnostics().value("triangles").toInt() > 0,
            qPrintable(view.bounds("officeViewport")+"; renderer="+view.viewport->error()+"; warnings="+view.warnings.join(';')),15000);
        QTRY_VERIFY(view.viewport->property("tourAvailable").toBool());
        QVERIFY(!view.viewport->property("immersive").toBool());
        QVERIFY(view.inside(view.find("officeEnter")));
        QVERIFY(view.capture("office-tour-overview-wide"));
        // Overview opens the rich agent drawer; repeated chat/roster updates
        // must not restart its network selection or interrupt the active tab.
        const auto overviewId=view.office.agents.first().toMap().value("id").toString();
        QSignalSpy openedFrames(&view.window, &QQuickWindow::frameSwapped);
        view.office.selectAgent(overviewId);
        QTRY_COMPARE(view.features.selectedId,overviewId);
        auto* drawer = view.find("officeChatDrawer");
        QVERIFY(drawer);
        // The panel is positioned inside the page even while its animated
        // parent is still clipped shut. Wait for the drawer's presented size.
        QTRY_COMPARE(drawer->width(), drawer->property("panelWidth").toReal());
        QTRY_VERIFY_WITH_TIMEOUT(openedFrames.count() >= 2, 3000);
        QTRY_VERIFY2(view.insideOffice(view.find("agentDetailPanel")),qPrintable(view.bounds("agentDetailPanel")));
        QVERIFY(view.insideOffice(view.find("agentDetailFooter")));
        QVERIFY(!view.find("officeImmersiveChat"));
        const auto selectionRequests=view.features.selectCount;
        emit view.office.changed(); emit view.features.changed();
        QCOMPARE(view.features.selectCount,selectionRequests);
        QVERIFY(view.click("agentDetailClose"));
        QTRY_VERIFY(view.office.selectedAgent.isEmpty());
        QVERIFY(view.features.selectedId.isEmpty());
        tourProgress("agent drawer opened and closed");
        QVERIFY(view.click("officeEnter"));
        QTRY_VERIFY(view.viewport->property("immersive").toBool());
        QTRY_VERIFY(view.inside(view.find("officeOverview")));
        QTRY_VERIFY(view.inside(view.find("officeTourMap")));
        QTRY_VERIFY(view.inside(view.find("officeTourDestination")));
        QTest::qWait(160);
        QVERIFY(view.capture("office-tour-entered-wide"));
        auto* anchors = view.viewport->tourAnchors();
        QVERIFY(anchors && anchors->rowCount() > 0);
        bool clickedAnchor = false;
        const auto roles = anchors->roleNames();
        const int idRole = roles.key("stopId"), visibleRole = roles.key("onScreen");
        for (int row = 0; row < anchors->rowCount(); ++row) {
            const auto index = anchors->index(row, 0);
            if (!anchors->data(index, visibleRole).toBool()) continue;
            const auto id = anchors->data(index, idRole).toString();
            if (id == view.viewport->tourCurrentStop()) continue;
            if (!view.click("officeAnchor_" + id)) continue;
            QTRY_COMPARE(view.viewport->tourDestination(), id);
            view.viewport->stopWalking(); clickedAnchor = true; break;
        }
        QVERIFY2(clickedAnchor, "A visible floor anchor must begin guided travel directly from the scene");

        const auto stops = view.viewport->property("tourStops").toList();
        QVERIFY(stops.size() > 1);
        const auto entryStop = view.viewport->property("tourCurrentStop").toString();
        QString mapStop;
        for (const auto& value : stops) {
            if (value.toMap().value("id").toString() != entryStop) {
                mapStop = value.toMap().value("id").toString(); break;
            }
        }
        QVERIFY(view.click("officeTourStop_" + mapStop));
        QTRY_COMPARE(view.viewport->property("tourDestination").toString(), mapStop);
        QVERIFY(QMetaObject::invokeMethod(view.viewport, "stopWalking"));

        // Choose an authored stop through the actual combo box's keyboard UI.
        auto* destinations = view.find("officeTourDestination");
        QVERIFY(destinations->property("count").toInt() > 1);
        const auto initialStop = view.viewport->property("tourCurrentStop").toString();
        QVERIFY(view.click(destinations));
        QTest::keyClick(&view.window, Qt::Key_End);
        QTest::keyClick(&view.window, Qt::Key_Return);
        QTRY_VERIFY(view.viewport->property("tourMoving").toBool()
            || view.viewport->property("tourCurrentStop").toString() != initialStop);
        const auto positionBeforeWalk = view.viewport->property("tourPosition").toPointF();
        QTRY_VERIFY_WITH_TIMEOUT(view.viewport->property("tourPosition").toPointF() != positionBeforeWalk, 2000);
        QVERIFY(QMetaObject::invokeMethod(view.viewport, "stopWalking"));
        QTRY_VERIFY(!view.viewport->property("tourMoving").toBool());

        // Dragging changes only the view; it must not create a new walking path.
        const auto positionBeforeLook = view.viewport->property("tourPosition").toPointF();
        const auto yawBeforeLook = view.viewport->property("tourYaw").toReal();
        const auto center = view.viewport->mapToScene({view.viewport->width() * .5, view.viewport->height() * .5}).toPoint();
        QTest::mousePress(&view.window, Qt::LeftButton, Qt::NoModifier, center);
        QTest::mouseMove(&view.window, center + QPoint(130, 25), 60);
        QTest::mouseRelease(&view.window, Qt::LeftButton, Qt::NoModifier, center + QPoint(130, 25));
        QTRY_VERIFY(view.viewport->property("tourYaw").toReal() != yawBeforeLook);
        QCOMPARE(view.viewport->property("tourPosition").toPointF(), positionBeforeLook);
        QVERIFY(!view.viewport->property("tourMoving").toBool());
        view.viewport->forceActiveFocus();
        const auto yawBeforeKey = view.viewport->property("tourYaw").toReal();
        QTest::keyPress(&view.window, Qt::Key_Left);
        QTest::qWait(180);
        QTest::keyRelease(&view.window, Qt::Key_Left);
        QTRY_VERIFY(view.viewport->property("tourYaw").toReal() != yawBeforeKey);
        tourProgress("walking, pointer and keyboard navigation verified");

        // Turn in place until a real projected agent badge can be selected.
        for (int turn = 0; turn < 12 && !view.visibleAgentBadge(); ++turn) {
            QVERIFY(QMetaObject::invokeMethod(view.viewport, "lookAround", Q_ARG(qreal, .52), Q_ARG(qreal, 0.)));
            QTest::qWait(100);
        }
        auto* badge = view.visibleAgentBadge();
        QVERIFY2(badge, "At least one seated synthetic colleague must be reachable by looking around");
        const auto agentId = badge->parentItem()->property("agentId").toString();
        QVERIFY(view.click(badge));
        QTRY_VERIFY2_WITH_TIMEOUT(view.office.selectedAgent.value("id").toString() == agentId,
            qPrintable(QString("requested=%1; selected=%2; pending=%3; destination=%4; current=%5; moving=%6; settling=%7; active=%8")
                .arg(agentId, view.office.selectedAgent.value("id").toString(),
                    view.find("officePageUnderTest")->property("approachingAgentId").toString(),
                    view.viewport->tourDestination(), view.viewport->tourCurrentStop())
                .arg(view.viewport->tourMoving()).arg(view.viewport->tourSettling()).arg(view.window.isActive())), 25000);
        tourProgress("agent approached and conversation opened");
        QTRY_VERIFY(view.inside(view.find("officeImmersiveChat")));
        QVERIFY(view.find("officeImmersiveChat")->property("compact").toBool());
        auto* composer = view.find("officeChatComposer");
        QVERIFY(composer);
        composer->forceActiveFocus();
        const auto chattingPosition = view.viewport->property("tourPosition").toPointF();
        const auto chattingYaw = view.viewport->property("tourYaw").toReal();
        for (const char key : QByteArray("What are you working on?")) QTest::keyClick(&view.window, key);
        QTRY_COMPARE(view.office.draft, QString("What are you working on?"));
        QCOMPARE(view.viewport->property("tourPosition").toPointF(), chattingPosition);
        QCOMPARE(view.viewport->property("tourYaw").toReal(), chattingYaw);
        QVERIFY(view.click("officeChatSend"));
        QTRY_COMPARE(view.office.sendCount, 1);
        QCOMPARE(view.office.submittedAgent, agentId);
        QCOMPARE(view.office.submittedBody, QString("What are you working on?"));
        QTRY_COMPARE(view.office.messages.size(), 2);
        QTRY_VERIFY(!view.office.sending);
        QVERIFY(view.office.draft.isEmpty());
        QTest::qWait(700); // Let the seated gaze settle for the conversation capture.
        QVERIFY(view.capture("office-tour-chat-wide"));
        tourProgress("chat send and reply verified");

        view.resize(1000, 680);
        QTest::qWait(180);
        QVERIFY(view.inside(view.find("officeOverview")));
        QVERIFY(view.inside(view.find("officeImmersiveChat")));
        QVERIFY(view.inside(view.find("officeChatSend")));
        QVERIFY(view.capture("office-tour-chat-compact"));
        // A minimum 1000x680 application window leaves roughly 750x580 for
        // OfficePage after its sidebar and top bar. Exercise that content size
        // as well as the standalone 1000x680 view above.
        view.resize(790, 640);
        QTest::qWait(180);
        QTRY_VERIFY(view.insideOffice(view.find("officeOverview")));
        QTRY_VERIFY(view.insideOffice(view.find("officeImmersiveChat")));
        QTRY_VERIFY(view.insideOffice(view.find("officeChatComposer")));
        QTRY_VERIFY(view.insideOffice(view.find("officeChatSend")));
        QTRY_VERIFY(view.insideOffice(view.find("officeTourDestination")));
        QVERIFY(!view.find("officeTourMap"));
        const auto* chat = view.find("officeImmersiveChat");
        const auto* destination = view.find("officeTourDestination");
        const QRectF chatBounds(chat->mapToScene({}), QSizeF(chat->width(), chat->height()));
        const QRectF destinationBounds(destination->mapToScene({}), QSizeF(destination->width(), destination->height()));
        QVERIFY(!chatBounds.intersects(destinationBounds));
        QVERIFY(view.capture("office-tour-chat-shell-minimum"));
        tourProgress("compact layouts verified");
        // Closing the chat and exiting are independent controls. A fresh draft
        // survives leaving immersion through the same production chat binding.
        composer->forceActiveFocus();
        for (const char key : QByteArray("Keep this draft")) QTest::keyClick(&view.window, key);
        QTRY_COMPARE(view.office.draft, QString("Keep this draft"));
        QVERIFY(view.click("officeOverview"));
        QTRY_VERIFY(!view.viewport->property("immersive").toBool());
        QVERIFY(!view.viewport->property("tourMoving").toBool());
        QVERIFY(view.office.selectedAgent.isEmpty());
        QTest::qWait(160);
        // Save the returned geometry even if a subsequent assertion catches an
        // overflow, so a layout regression has a reviewable GPU-rendered frame.
        QVERIFY(view.capture("office-tour-returned-compact"));
        QTRY_VERIFY(view.insideOffice(view.find("officeEnter")));
        view.office.selectAgent(agentId);
        QCOMPARE(view.office.draft, QString("Keep this draft"));
        QTRY_COMPARE(view.features.selectedId,agentId);
        QTRY_VERIFY(view.insideOffice(view.find("agentDetailPanel")));
        QVERIFY(view.click("agentDetailChat"));
        QTRY_VERIFY(view.insideOffice(view.find("officeChatComposer")));
        QCOMPARE(view.find("officeChatComposer")->property("text").toString(),QString("Keep this draft"));
        QVERIFY(view.click("agentDetailChat"));

        // An overview with an existing conversation restores that exact agent
        // after an immersive conversation with somebody else.
        const auto priorAgent = view.office.agents.first().toMap().value("id").toString();
        const auto visitingAgent = view.office.agents.last().toMap().value("id").toString();
        QVERIFY(priorAgent != visitingAgent);
        view.office.selectAgent(priorAgent);
        QTRY_VERIFY(view.insideOffice(view.find("officeEnter")));
        QVERIFY(view.click("officeEnter"));
        QTRY_VERIFY(view.viewport->property("immersive").toBool());
        auto* officePage = view.find("officePageUnderTest");
        QVERIFY(officePage);
        QTRY_COMPARE(view.viewport->width(), officePage->width());
        // Mode state changes synchronously, but Qt Quick polishes the newly
        // expanded page on a later frame. Wait for presented geometry before
        // calculating the next pointer click's scene position.
        QSignalSpy enteredFrames(&view.window, &QQuickWindow::frameSwapped);
        QTRY_VERIFY_WITH_TIMEOUT(enteredFrames.count() >= 2, 3000);
        view.office.selectAgent(visitingAgent);
        QTRY_COMPARE(view.office.selectedAgent.value("id").toString(), visitingAgent);
        QTRY_VERIFY(view.insideOffice(view.find("officeOverview")));
        const auto* overview = view.find("officeOverview");
        QVERIFY(overview->mapToScene(QPointF{}).y() + overview->height()
            <= view.viewport->mapToScene(QPointF{}).y());
        QVERIFY(view.capture("office-tour-restore-open-chat-before-exit"));
        QVERIFY(view.click("officeOverview"));
        QTRY_VERIFY(!view.viewport->property("immersive").toBool());
        QTRY_COMPARE(view.office.selectedAgent.value("id").toString(), priorAgent);
        QTRY_COMPARE(view.features.selectedId,priorAgent);
        QTRY_VERIFY(view.insideOffice(view.find("agentDetailPanel")));

        // Escape also returns to the saved overview while the chat composer,
        // rather than the scene, owns keyboard focus.
        QTest::qWait(160);
        QVERIFY(view.click("officeEnter"));
        QTRY_VERIFY(view.viewport->property("immersive").toBool());
        QTRY_COMPARE(view.viewport->width(), officePage->width());
        view.office.selectAgent(visitingAgent);
        QTRY_VERIFY(view.insideOffice(view.find("officeChatComposer")));
        view.find("officeChatComposer")->forceActiveFocus();
        QTest::keyClick(&view.window, Qt::Key_Escape);
        QTRY_VERIFY(!view.viewport->property("immersive").toBool());
        QTRY_COMPARE(view.office.selectedAgent.value("id").toString(), priorAgent);
        QVERIFY2(view.viewport->error().isEmpty(), qPrintable(view.viewport->error()));
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
        tourProgress("interactive tour scenario complete");
    }
};

int main(int argc, char** argv) {
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::setvbuf(stderr, nullptr, _IONBF, 0);
    tourProgress("process started");
#ifdef Q_OS_MACOS
    QQuickWindow::setGraphicsApi(QSGRendererInterface::Metal);
#elif defined(Q_OS_WIN)
    QQuickWindow::setGraphicsApi(QSGRendererInterface::Direct3D11);
#endif
    QGuiApplication app(argc, argv);
    tourProgress("Qt application initialized");
    QCoreApplication::setApplicationName("Mokaid office tour tests — synthetic data");
    QQuickStyle::setStyle("Basic");
    QFontDatabase::addApplicationFont(QStringLiteral(MOKAID_OFFICE_QML_DIRECTORY) + "/../assets/fonts/Manrope.ttf");
    mokaid::registerViewportTypes();
    OfficeTourQmlTests tests;
    return QTest::qExec(&tests, argc, argv);
}
#include "office_tour_qml_tests.moc"
