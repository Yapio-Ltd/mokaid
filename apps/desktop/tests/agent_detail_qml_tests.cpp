#include <mokaid/features/feature_controller.hpp>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFontDatabase>
#include <QGuiApplication>
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

// Every record and request in these tests is an authored fixture served from
// loopback. Captures never access a production account or saved user content.
class AgentDetailApi final : public QObject {
public:
    QTcpServer server;
    QHash<QString, QJsonObject> responses;
    QStringList methods, paths;
    QList<QJsonObject> bodies;
    AgentDetailApi() {
        server.listen(QHostAddress::LocalHost, 0);
        connect(&server, &QTcpServer::newConnection, this, [this] {
            while (server.hasPendingConnections()) {
                auto* socket = server.nextPendingConnection();
                connect(socket, &QTcpSocket::disconnected, socket, &QObject::deleteLater);
                connect(socket, &QTcpSocket::readyRead, this, [this, socket] {
                    const auto request = socket->property("request").toByteArray() + socket->readAll();
                    socket->setProperty("request", request);
                    const auto headersEnd = request.indexOf("\r\n\r\n");
                    if (headersEnd < 0 || socket->property("handled").toBool()) return;
                    qsizetype length = 0;
                    for (const auto& line : request.left(headersEnd).split('\n'))
                        if (line.toLower().startsWith("content-length:")) length = line.mid(15).trimmed().toLongLong();
                    if (request.size() < headersEnd + 4 + length) return;
                    socket->setProperty("handled", true);
                    const auto method = QString::fromUtf8(request.split(' ').value(0));
                    const auto path = QString::fromUtf8(request.split(' ').value(1)).section('?', 0, 0);
                    const auto payload = QJsonDocument::fromJson(request.mid(headersEnd + 4, length)).object();
                    methods.append(method); paths.append(path); bodies.append(payload);
                    if (method == "PATCH" && path == "/api/agents/fixture-taya") {
                        auto agent = responses.value(path).value("data").toObject();
                        for (auto it = payload.begin(); it != payload.end(); ++it) agent.insert(it.key(), it.value());
                        responses.insert(path, {{"data", agent}});
                        responses.insert("/api/agents", {{"data", QJsonArray{agent}}});
                    }
                    const auto response = responses.value(method + " " + path, responses.value(path, QJsonObject{{"data", QJsonArray{}}}));
                    const auto body = QJsonDocument(response).toJson(QJsonDocument::Compact);
                    socket->write("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: "
                        + QByteArray::number(body.size()) + "\r\n\r\n" + body);
                    socket->disconnectFromHost();
                });
            }
        });
    }
    QUrl origin() const { return QUrl(QString("http://127.0.0.1:%1").arg(server.serverPort())); }
    int count(const QString& method, const QString& path) const {
        int result = 0;
        for (qsizetype i = 0; i < paths.size(); ++i) if (methods.at(i) == method && paths.at(i) == path) ++result;
        return result;
    }
    QJsonObject lastBody(const QString& method, const QString& path) const {
        for (qsizetype i = paths.size(); i-- > 0;) if (methods.at(i) == method && paths.at(i) == path) return bodies.at(i);
        return {};
    }
};

class AgentDetailContext final : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantMap selectedAgent MEMBER selectedAgent NOTIFY changed)
    Q_PROPERTY(QVariantList conversations MEMBER conversations NOTIFY changed)
    Q_PROPERTY(QVariantList messages MEMBER messages NOTIFY changed)
    Q_PROPERTY(QString conversationId MEMBER conversationId NOTIFY changed)
    Q_PROPERTY(QString draft MEMBER draft NOTIFY changed)
    Q_PROPERTY(QString stream MEMBER stream NOTIFY changed)
    Q_PROPERTY(QString error MEMBER error NOTIFY changed)
    Q_PROPERTY(bool loading MEMBER loading NOTIFY changed)
    Q_PROPERTY(bool sending MEMBER sending NOTIFY changed)
    Q_PROPERTY(bool reducedMotion READ reducedMotion CONSTANT)
    Q_PROPERTY(bool online READ online CONSTANT)
    Q_PROPERTY(QString workspaceId READ workspaceId CONSTANT)
public:
    QVariantMap selectedAgent, availableAgent;
    QVariantList conversations, messages;
    QString conversationId, draft, stream, error, missionAgent, selectedAgentId;
    bool loading = false, sending = false;
    int sendCount = 0;
    bool reducedMotion() const { return true; }
    bool online() const { return true; }
    QString workspaceId() const { return "fixture-workspace"; }
    Q_INVOKABLE void selectAgent(const QString& id) { selectedAgentId = id; selectedAgent = availableAgent; emit changed(); }
    Q_INVOKABLE void closeChat() { selectedAgentId.clear(); emit changed(); }
    Q_INVOKABLE void beginForAgent(const QString& id) { missionAgent = id; }
    Q_INVOKABLE void beginForAgent(const QString& id, const QString&) { missionAgent = id; }
    Q_INVOKABLE void selectConversation(const QString& id) { conversationId = id; emit changed(); }
    Q_INVOKABLE void newConversation() { conversationId.clear(); messages.clear(); emit changed(); }
    Q_INVOKABLE void send(const QVariantList&) {
        ++sendCount;
        messages.append(QVariantMap{{"id", "fixture-message"}, {"author_kind", "member"}, {"body", draft}});
        draft.clear(); emit changed();
    }
signals:
    void changed();
};

static QJsonObject detailAgent() {
    return {{"id", "fixture-taya"}, {"display_name", "Taya"}, {"role_title", "Legal Specialist"}, {"kind", "ai"},
        {"status", "busy"}, {"avatar_cdn_path", "/assets3d/avatar_legal.0123456789ab.glb"},
        {"skills", QJsonArray{"Legal", "Contracts", "Research", "Compliance", "Analysis"}},
        {"missions_completed", 248}, {"performance_score", 98}, {"level", 10}, {"xp", 850}, {"xp_for_next_level", 1000},
        {"model_quality", "smart"}, {"autonomy_mode", "balanced"}, {"current_task_id", "fixture-draft"},
        {"description", "Contracts, compliance, and legal research — done in minutes."},
        {"instructions", "Review contracts, identify risks and explain recommendations clearly. Ask for approval before sending any document."},
        {"last_active_at", "2026-09-26T16:00:00Z"}, {"inserted_at", "2026-09-01T10:00:00Z"}};
}

static QJsonArray detailTasks() {
    const auto row = [](const QString& id, const QString& title, const QString& status, int hours, int progress) {
        return QJsonObject{{"id", id}, {"title", title}, {"status", status}, {"assigned_agent_id", "fixture-taya"},
            {"description", "Prepare a clear recommendation based on the workspace reference material."},
            {"progress_percent", progress}, {"inserted_at", "2026-09-25T08:00:00Z"},
            {"started_at", "2026-09-25T09:00:00Z"},
            {"updated_at", QDateTime::currentDateTimeUtc().addSecs(-hours * 3600).toString(Qt::ISODate)},
            {"completed_at", status == "completed" ? QJsonValue("2026-09-25T21:00:00Z") : QJsonValue::Null}};
    };
    return {row("fixture-review", "Review partnership agreement", "completed", 2, 100),
        row("fixture-regulation", "Analyze Israeli regulation", "completed", 5, 100),
        row("fixture-draft", "Draft legal memo", "in_progress", 12, 48),
        row("fixture-research", "Research tax implications", "to_do", 16, 0),
        QJsonObject{{"id", "other-task"}, {"title", "Another agent’s private task"}, {"status", "in_progress"}, {"assigned_agent_id", "other-agent"}}};
}

struct AgentDetailFixture {
    AgentDetailApi remote;
    QTemporaryDir cacheDirectory;
    ApiClient api{remote.origin()};
    PhoenixClient realtime;
    SessionController session{api, realtime};
    CacheStore cache{cacheDirectory.path()};
    FeatureController features{api, session, cache};
    AgentDetailContext context;
    AgentDetailFixture() {
        api.setSession("test-only-session", "fixture-user", false); api.setWorkspace("fixture-workspace");
        context.availableAgent = detailAgent().toVariantMap();
        remote.responses.insert("/api/agents", {{"data", QJsonArray{detailAgent()}}});
        remote.responses.insert("/api/agents/fixture-taya", {{"data", detailAgent()}});
        remote.responses.insert("/api/tasks", {{"data", detailTasks()}});
        remote.responses.insert("/api/knowledge", {{"data", QJsonArray{
            QJsonObject{{"id", "fixture-contract"}, {"agent_id", "fixture-taya"}, {"title", "Partnership agreement.pdf"}, {"type", "file"}, {"file_size_bytes", 24576}, {"status", "ready"}, {"indexing_status", "indexed"}},
            QJsonObject{{"id", "fixture-policy"}, {"agent_id", "fixture-taya"}, {"title", "Workspace policy.md"}, {"type", "file"}, {"file_size_bytes", 8192}, {"status", "ready"}, {"indexing_status", "indexed"}}}}});
        remote.responses.insert("/api/agents/fixture-taya/progression", {{"data", QJsonObject{{"level", 10}, {"xp", 850}, {"xp_for_next_level", 1000}, {"skills", QJsonArray{"Legal", "Contracts", "Research"}}}}});
        remote.responses.insert("/api/agents/fixture-taya/training", {{"data", QJsonObject{{"complete?", true}, {"target_level", 10}, {"domain_pack", QJsonObject{{"seeded_count", 24}, {"pending_count", 0}}}}}});
    }
};

class AgentDetailView final {
public:
    QTemporaryDir directory;
    QQmlEngine engine;
    QStringList warnings;
    std::unique_ptr<QObject> page;
    QQuickWindow window;
    QQuickItem* item{};
    QString failure;
    explicit AgentDetailView(AgentDetailFixture& fixture) {
        for (const auto& name : QDir(QStringLiteral(MOKAID_AGENT_DETAIL_QML_DIRECTORY)).entryList({"*.qml", "*.js"}, QDir::Files))
            QFile::copy(QStringLiteral(MOKAID_AGENT_DETAIL_QML_DIRECTORY) + "/" + name, directory.path() + "/" + name);
        QFile qmldir(directory.path() + "/qmldir");
        if (!qmldir.open(QIODevice::WriteOnly)) { failure = "Cannot create isolated QML module"; return; }
        qmldir.write("singleton Theme 1.0 Theme.qml\n"); qmldir.close();
        QObject::connect(&engine, &QQmlEngine::warnings, &engine, [this](const QList<QQmlError>& errors) {
            for (const auto& error : errors) warnings.append(error.toString());
        });
        engine.rootContext()->setContextProperty("features", &fixture.features);
        for (const auto* name : {"office", "missions", "session", "system"}) engine.rootContext()->setContextProperty(name, &fixture.context);
        QQmlComponent component(&engine);
        component.setData("import QtQuick\nAgentDetailPanel { agent: features.selectedRecord }", QUrl::fromLocalFile(directory.path() + "/Fixture.qml"));
        page.reset(component.create()); failure = component.errorString();
        item = qobject_cast<QQuickItem*>(page.get());
        if (!item) return;
        window.setColor(QColor("#090b13")); item->setParentItem(window.contentItem()); resize(450, 850); window.show();
    }
    ~AgentDetailView() { if (item) item->setParentItem(nullptr); }
    void resize(int width, int height) { window.resize(width, height); if (item) item->setSize(QSizeF(width, height)); polish(); }
    void polish() { QCoreApplication::processEvents(); window.grabWindow(); }
    QList<QQuickItem*> children() const {
        QList<QQuickItem*> result{window.contentItem()};
        for (qsizetype i = 0; i < result.size(); ++i) result.append(result.at(i)->childItems());
        return result;
    }
    QQuickItem* find(const QString& name) const {
        for (auto* child : children())
            if (child->objectName() == name && child->isVisible() && child->width() > 1 && child->height() > 1) return child;
        return nullptr;
    }
    bool click(const QString& name) {
        polish(); auto* control = find(name); if (!control) return false;
        QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier,
            control->mapToScene(QPointF(control->width() / 2, control->height() / 2)).toPoint());
        polish(); return true;
    }
    bool reveal(const QString& name) {
        polish(); auto* control = find(name); if (!control) return false;
        for (auto* ancestor = control->parentItem(); ancestor; ancestor = ancestor->parentItem()) {
            if (ancestor->metaObject()->indexOfProperty("contentY") < 0) continue;
            const auto offset = control->mapToItem(ancestor, QPointF(0, control->height() / 2)).y() - ancestor->height() / 2;
            const auto limit = qMax(0., ancestor->property("contentHeight").toReal() - ancestor->height());
            ancestor->setProperty("contentY", qBound(0., ancestor->property("contentY").toReal() + offset, limit));
            polish();
        }
        return inside(name);
    }
    bool inside(const QString& name) const {
        const auto* control = find(name); if (!control) return false;
        const auto point = control->mapToItem(item, QPointF());
        return point.x() >= -1 && point.y() >= -1 && point.x() + control->width() <= item->width() + 1
            && point.y() + control->height() <= item->height() + 1;
    }
    bool within(const QString& name, const QString& ancestorName) const {
        const auto* control = find(name); const auto* ancestor = find(ancestorName);
        if (!control || !ancestor) return false;
        const auto bounds = control->mapRectToItem(ancestor, QRectF(0, 0, control->width(), control->height()));
        return bounds.left() >= -1 && bounds.top() >= -1
            && bounds.right() <= ancestor->width() + 1 && bounds.bottom() <= ancestor->height() + 1;
    }
    bool capture(const QString& name) {
        const auto output = qEnvironmentVariable("MOKAID_AGENT_DETAIL_CAPTURE_DIR");
        if (output.isEmpty()) return true;
        polish(); QDir().mkpath(output); return window.grabWindow().save(output + "/" + name + ".png");
    }
};

class AgentDetailQmlTests final : public QObject {
    Q_OBJECT
    static QVariant property(QObject* object, const char* name) {
        const auto value = object->property(name);
        return value.metaType() == QMetaType::fromType<QJSValue>() ? value.value<QJSValue>().toVariant() : value;
    }
private slots:
    void tabsAndPersistentActionsFitAtReferenceAndCompactSizes() {
        AgentDetailFixture fixture;
        QVERIFY(fixture.remote.server.isListening());
        fixture.features.openRecord("agents", "fixture-taya");
        QTRY_COMPARE(fixture.features.selectedAgentTasksState(), QString("ready"));
        AgentDetailView view(fixture); QVERIFY2(view.item, qPrintable(view.failure));
        QTRY_VERIFY(!fixture.features.busy()); QTest::qWait(80);
        QCOMPARE(fixture.features.selectedAgentTasks().size(), 4);
        for (const QSize size : {QSize(450, 850), QSize(360, 600), QSize(340, 500)}) {
            view.resize(size.width(), size.height());
            for (int tab = 0; tab < 4; ++tab) {
                QVERIFY2(view.click("agentTab_" + QString::number(tab)), qPrintable("Cannot click tab " + QString::number(tab)));
                QTRY_COMPARE(view.page->property("currentTab").toInt(), tab);
                QTRY_VERIFY(!fixture.features.busy()); view.polish();
                for (const auto* name : {"agentDetailClose", "agentTab_0", "agentTab_3", "agentDetailChat", "agentDetailAssign", "agentDetailUpload", "agentDetailRent", "agentDetailMore"})
                    QVERIFY2(view.inside(name), qPrintable(QString("%1 is clipped at %2×%3 on tab %4").arg(name).arg(size.width()).arg(size.height()).arg(tab)));
                QVERIFY(view.within("agentDetailClose", "agentDetailProfile"));
                if (size.height() >= 600)
                    QVERIFY2(view.within("agentDetailMetrics", "agentDetailProfile"), "Agent metrics must remain inside the profile card");
                QVERIFY(view.capture(QString("agent-detail-%1-tab-%2").arg(size.width()).arg(tab)));
            }
        }
        QVERIFY(view.click("agentTab_0")); view.find("agentTab_0")->forceActiveFocus();
        QTest::keyClick(&view.window, Qt::Key_Right);
        QTRY_COMPARE(view.page->property("currentTab").toInt(), 1);
        QVERIFY(view.find("agentTab_1")->hasActiveFocus());
        QSignalSpy closed(view.page.get(), SIGNAL(closed())); QVERIFY(closed.isValid());
        QVERIFY(view.click("agentDetailClose")); QCOMPARE(closed.count(), 1);
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }

    void chatSendsDraftAndReturnsToOverviewWithoutLosingThePanel() {
        AgentDetailFixture fixture; fixture.features.openRecord("agents", "fixture-taya");
        QTRY_COMPARE(fixture.features.selectedAgentTasksState(), QString("ready"));
        AgentDetailView view(fixture); QVERIFY2(view.item, qPrintable(view.failure));
        view.resize(360, 600);
        QVERIFY(view.click("agentDetailChat"));
        QTRY_VERIFY(view.page->property("chatOpen").toBool());
        QCOMPARE(fixture.context.selectedAgentId, QString("fixture-taya"));
        QTRY_VERIFY(view.find("officeChatComposer"));
        auto* composer = view.find("officeChatComposer");
        QVERIFY(composer->setProperty("text", "Peux-tu résumer les points à vérifier dans le contrat ?"));
        view.polish(); QVERIFY(view.inside("officeChatComposer")); QVERIFY(view.inside("officeChatSend"));
        QVERIFY(view.capture("agent-detail-360-chat"));
        QVERIFY(view.click("officeChatSend")); QCOMPARE(fixture.context.sendCount, 1);
        QVERIFY(fixture.context.draft.isEmpty()); QCOMPARE(fixture.context.messages.size(), 1);
        QVERIFY(view.capture("agent-detail-360-chat-message"));
        composer->forceActiveFocus(); QTest::keyClick(&view.window, Qt::Key_Escape);
        QTRY_VERIFY(!view.page->property("chatOpen").toBool());
        QVERIFY(view.inside("agentDetailChat"));
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }

    void missionUploadAndMarketplaceActionsKeepTheSelectedAgent() {
        AgentDetailFixture fixture; fixture.features.openRecord("agents", "fixture-taya");
        QTRY_COMPARE(fixture.features.selectedAgentTasksState(), QString("ready"));
        AgentDetailView view(fixture); QVERIFY2(view.item, qPrintable(view.failure));
        QSignalSpy requested(view.page.get(), SIGNAL(actionRequested(QVariant))); QVERIFY(requested.isValid());
        QVERIFY(view.click("agentDetailAssign")); QCOMPARE(fixture.context.missionAgent, QString("fixture-taya"));
        QVERIFY(view.click("agentDetailUpload")); QTRY_COMPARE(requested.count(), 1);
        const auto upload = requested.first().first();
        const auto uploadMap = upload.metaType() == QMetaType::fromType<QJSValue>() ? upload.value<QJSValue>().toVariant().toMap() : upload.toMap();
        QCOMPARE(uploadMap.value("id").toString(), QString("upload"));
        QVERIFY(view.click("agentDetailMore")); view.polish(); QVERIFY(view.capture("agent-detail-450-more"));
        QTest::keyClick(&view.window, Qt::Key_Escape); view.polish();
        QVERIFY(view.click("agentDetailRent"));
        QTRY_COMPARE(fixture.features.currentPage(), QString("marketplace"));
        QCOMPARE(fixture.features.pendingOfferAgentId(), QString("fixture-taya"));
        QCOMPARE(fixture.features.pendingOfferMode(), QString("rent"));
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }

    void settingsSavePersistsActualEdits() {
        AgentDetailFixture fixture; fixture.features.openRecord("agents", "fixture-taya");
        QTRY_COMPARE(fixture.features.selectedAgentTasksState(), QString("ready"));
        AgentDetailView view(fixture); QVERIFY2(view.item, qPrintable(view.failure));
        QVERIFY(view.click("agentTab_3")); QTRY_VERIFY(view.find("agentSettingsName"));
        auto* name = view.find("agentSettingsName"); QVERIFY(name->setProperty("text", "Taya — Legal"));
        auto* role = view.find("agentSettingsRole"); QVERIFY(role); QVERIFY(role->setProperty("text", "Contract Specialist"));
        view.polish();
        QVERIFY(view.find("agentSettingsSave")); QTRY_VERIFY(view.find("agentSettingsSave")->isEnabled());
        QVERIFY(view.reveal("agentSettingsSave")); QVERIFY(view.click("agentSettingsSave"));
        QTRY_COMPARE(fixture.remote.count("PATCH", "/api/agents/fixture-taya"), 1);
        const auto saved = fixture.remote.lastBody("PATCH", "/api/agents/fixture-taya");
        QCOMPARE(saved.value("display_name").toString(), QString("Taya — Legal"));
        QCOMPARE(saved.value("role_title").toString(), QString("Contract Specialist"));
        QVERIFY(!saved.contains("instructions"));
        QTRY_VERIFY(!fixture.features.busy());
        QTRY_COMPARE(fixture.features.selectedRecord().value("display_name").toString(), QString("Taya — Legal"));
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }

    void taskFiltersSearchAndSelectionUseOnlyThisAgentsTasks() {
        AgentDetailFixture fixture; fixture.features.openRecord("agents", "fixture-taya");
        QTRY_COMPARE(fixture.features.selectedAgentTasksState(), QString("ready"));
        AgentDetailView view(fixture); QVERIFY2(view.item, qPrintable(view.failure));
        QVERIFY(view.click("agentTab_1")); QTRY_VERIFY(view.find("agentTasksList"));
        auto* list = view.find("agentTasksList"); QCOMPARE(list->property("count").toInt(), 4);
        QVERIFY(view.click("agentTaskFilter_2")); QTRY_COMPARE(list->property("count").toInt(), 2);
        QVERIFY(view.find("agentTaskSearch")->setProperty("text", "agreement"));
        QTRY_COMPARE(list->property("count").toInt(), 1);
        QVERIFY(view.find("agentTaskSearch")->setProperty("text", "no matching title"));
        QTRY_COMPARE(list->property("count").toInt(), 0);
        QVERIFY(view.capture("agent-detail-450-tasks-empty-search"));
        QVERIFY(view.find("agentTaskSearch")->setProperty("text", ""));
        QVERIFY(view.click("agentTaskFilter_1")); QTRY_COMPARE(list->property("count").toInt(), 2);
        QTRY_VERIFY(view.find("agentTask_fixture-draft"));
        QVERIFY(view.click("agentTask_fixture-draft"));
        QTRY_COMPARE(fixture.features.currentPage(), QString("tasks"));
        QTRY_COMPARE(fixture.features.selectedId(), QString("fixture-draft"));
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }

    void knowledgeRefreshAndUploadUseTheSelectedAgentsLibrary() {
        AgentDetailFixture fixture; fixture.features.openRecord("agents", "fixture-taya");
        QTRY_COMPARE(fixture.features.selectedAgentKnowledgeState(), QString("ready"));
        AgentDetailView view(fixture); QVERIFY2(view.item, qPrintable(view.failure));
        QVERIFY(view.click("agentTab_2"));
        QTRY_COMPARE(fixture.features.selectedAgentKnowledge().size(), 2);
        QTRY_VERIFY(!fixture.features.busy());
        QVERIFY(view.find("agentKnowledge_fixture-contract"));
        QVERIFY(view.find("agentKnowledge_fixture-policy"));
        const auto originalRequests = fixture.remote.count("GET", "/api/knowledge");
        QVERIFY(view.click("agentKnowledgeRefresh"));
        QTRY_VERIFY(fixture.remote.count("GET", "/api/knowledge") > originalRequests);
        QTRY_COMPARE(fixture.features.selectedAgentKnowledgeState(), QString("ready"));
        QSignalSpy requested(view.page.get(), SIGNAL(actionRequested(QVariant))); QVERIFY(requested.isValid());
        QTRY_VERIFY(view.find("agentKnowledgeUpload")->isEnabled());
        QVERIFY(view.click("agentKnowledgeUpload")); QTRY_COMPARE(requested.count(), 1);
        const auto upload = requested.first().first();
        const auto values = upload.metaType() == QMetaType::fromType<QJSValue>() ? upload.value<QJSValue>().toVariant().toMap() : upload.toMap();
        QCOMPARE(values.value("id").toString(), QString("upload"));
        QCOMPARE(fixture.features.selectedId(), QString("fixture-taya"));
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }
};

int main(int argc, char** argv) {
    qputenv("QT_QPA_PLATFORM", "offscreen");
    QQuickWindow::setGraphicsApi(QSGRendererInterface::Software); QQuickStyle::setStyle("Basic");
    QGuiApplication app(argc, argv);
    QTemporaryDir settingsDirectory;
    QCoreApplication::setOrganizationName("MokaidTests"); QCoreApplication::setApplicationName("AgentDetail");
    QSettings::setDefaultFormat(QSettings::IniFormat);
    QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, settingsDirectory.path());
    QFontDatabase::addApplicationFont(QStringLiteral(MOKAID_AGENT_DETAIL_QML_DIRECTORY) + "/../assets/fonts/Manrope.ttf");
    AgentDetailQmlTests tests; return QTest::qExec(&tests, argc, argv);
}

#include "agent_detail_qml_tests.moc"
