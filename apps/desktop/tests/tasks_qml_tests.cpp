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
#include <QTimeZone>
#include <QUuid>
#include <QtTest>
#include <memory>

using namespace mokaid::desktop;

// The entire view uses an isolated FeatureController and loopback API. These
// records are authored fixtures; no production account or content is accessed.
class TasksApi final : public QObject {
public:
    QTcpServer server;
    QJsonArray rows;
    QStringList methods, paths;
    QList<QJsonObject> bodies;
    int patchStatus = 200;
    int patchDelay = 0;
    int commentStatus = 200;
    int feedbackStatus = 200;
    int feedbackDelay = 0;
    int budgetStatus = 200;
    TasksApi() {
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
                    QJsonObject result{{"data", QJsonArray{}}};
                    int status = 200;
                    if (path == "/api/tasks") {
                        result = {{"data", rows}, {"meta", QJsonObject{{"current_member_id", "fixture-member"}, {"can_update", true}}}};
                    } else if (path.startsWith("/api/tasks/")) {
                        const auto id = path.section('/', 3, 3);
                        for (qsizetype i = 0; i < rows.size(); ++i) {
                            auto row = rows.at(i).toObject();
                            if (row.value("id").toString() != id) continue;
                            if (method == "PATCH") {
                                status = patchStatus;
                                if (status == 200) {
                                    for (auto it = payload.begin(); it != payload.end(); ++it) row.insert(it.key(), it.value());
                                    rows.replace(i, row);
                                }
                            } else if (method == "POST" && path.endsWith("/comments")) {
                                status = commentStatus;
                                if (status == 200) {
                                    auto comments = row.value("comments").toArray();
                                    comments.append(QJsonObject{{"id", "new-comment"}, {"body", payload.value("body")}, {"author_name", "Tom Jami"}});
                                    row.insert("comments", comments); rows.replace(i, row);
                                }
                            } else if (method == "POST" && path.endsWith("/runtime-budget")) {
                                status = budgetStatus;
                                if (status == 200) {
                                    auto run = row.value("latest_run").toObject();
                                    run.insert("status", "running");
                                    auto output = run.value("output").toObject();
                                    auto runtime = output.value("runtime").toObject();
                                    runtime.insert("status", "running"); output.insert("runtime", runtime); run.insert("output", output);
                                    row.insert("latest_run", run); rows.replace(i, row);
                                }
                            } else if (method == "POST" && path.endsWith("/feedback")) {
                                status = feedbackStatus;
                                if (status == 200) {
                                    row.insert("response_feedback", payload);
                                    if (payload.value("rating") == "good") row.insert("status", "completed");
                                    if (payload.value("rating") == "needs_improvement") {
                                        row.insert("status", "in_progress");
                                        row.remove("pending_approval");
                                        row.insert("latest_run", QJsonObject{{"id", "continued-" + id}, {"status", "queued"}});
                                    }
                                    rows.replace(i, row);
                                }
                            }
                            result = {{"data", row}};
                            break;
                        }
                    }
                    if (status != 200) result = {{"error", QJsonObject{{"message", path.endsWith("/feedback")
                        ? "The feedback could not be saved. Try again." : "This task could not be moved. Try again."}}}};
                    const auto send = [socket, result, status] {
                        const auto body = QJsonDocument(result).toJson(QJsonDocument::Compact);
                        socket->write("HTTP/1.1 " + QByteArray::number(status) + (status == 200 ? " OK" : " Unprocessable Entity")
                            + "\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: "
                            + QByteArray::number(body.size()) + "\r\n\r\n" + body);
                        socket->disconnectFromHost();
                    };
                    if (method == "POST" && path.endsWith("/feedback") && feedbackDelay > 0) QTimer::singleShot(feedbackDelay, socket, send);
                    else if (method == "PATCH" && patchDelay > 0) QTimer::singleShot(patchDelay, socket, send);
                    else send();
                });
            }
        });
    }
    QUrl origin() const { return QUrl(QString("http://127.0.0.1:%1").arg(server.serverPort())); }
    int patchCount() const { return methods.count("PATCH"); }
    QJsonObject lastPatch() const {
        for (qsizetype i = methods.size() - 1; i >= 0; --i) if (methods.at(i) == "PATCH") return bodies.at(i);
        return {};
    }
    void updateTask(const QString& id, const QJsonObject& values) {
        for (qsizetype i = 0; i < rows.size(); ++i) {
            auto row = rows.at(i).toObject();
            if (row.value("id").toString() != id) continue;
            for (auto it = values.begin(); it != values.end(); ++it) row.insert(it.key(), it.value());
            rows.replace(i, row);
            return;
        }
    }
    int feedbackCount() const {
        int count = 0;
        for (qsizetype i = 0; i < paths.size(); ++i)
            if (methods.at(i) == "POST" && paths.at(i).endsWith("/feedback")) ++count;
        return count;
    }
    QJsonObject lastFeedback() const {
        for (qsizetype i = paths.size() - 1; i >= 0; --i)
            if (methods.at(i) == "POST" && paths.at(i).endsWith("/feedback")) return bodies.at(i);
        return {};
    }
};

class TasksSession final : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool online READ online CONSTANT)
    Q_PROPERTY(QString workspaceId READ workspaceId CONSTANT)
    Q_PROPERTY(QVariantMap user READ user CONSTANT)
public:
    bool online() const { return true; }
    QString workspaceId() const { return "fixture-workspace"; }
    QVariantMap user() const { return {{"id", "fixture-user"}, {"full_name", "Tom Jami"}}; }
};

static QJsonArray taskFixtures() {
    QJsonArray rows;
    const auto add = [&rows](const char* id, const QString& title, const char* status, const char* tag,
                            const char* name, const char* portrait, int dueDays, int progress = 0, const char* priority = "medium") {
        const auto agentId = "agent-" + QString::fromUtf8(name).toLower();
        const auto avatar = QString("/assets3d/avatar_%1.0123456789ab.glb").arg(portrait);
        rows.append(QJsonObject{{"id", id}, {"workspace_id", "fixture-workspace"}, {"title", title},
            {"description", "Prendre connaissance du contexte, préparer une proposition claire et vérifier le résultat avant livraison.\n\nLe travail doit rester cohérent avec la direction artistique de Mokaid."},
            {"status", status}, {"priority", priority}, {"tags", QJsonArray{tag}}, {"project_name", "Mokaid workspace"},
            {"assigned_agent_id", agentId}, {"assigned_agent_name", name}, {"assigned_agent_kind", "ai"},
            {"assigned_agent_avatar_cdn_path", avatar}, {"assigned_agent", QJsonObject{{"id", agentId}, {"display_name", name}, {"kind", "ai"}, {"avatar_cdn_path", avatar}}},
            {"created_by_member_id", rows.size() < 8 ? "fixture-member" : "another-member"},
            {"assigned_member_id", rows.size() < 6 ? "fixture-member" : "another-member"},
            {"due_at", QDateTime(QDate::currentDate().addDays(dueDays), QTime(23, 59), QTimeZone::systemTimeZone()).toString(Qt::ISODate)},
            {"progress_percent", progress}, {"inserted_at", "2026-09-20T09:00:00Z"},
            {"subtask_count", 3}, {"subtask_done_count", 1},
            {"subtasks", QJsonArray{QJsonObject{{"id", "step-1"}, {"title", "Comprendre le besoin"}, {"done", true}}, QJsonObject{{"id", "step-2"}, {"title", "Préparer la proposition"}, {"done", false}}, QJsonObject{{"id", "step-3"}, {"title", "Vérifier et livrer"}, {"done", false}}}},
            {"comments", QJsonArray{QJsonObject{{"id", "comment-1"}, {"body", "Le brief est prêt. Je m’occupe de la première version."}, {"author_name", "Taya"}, {"inserted_at", "2026-09-25T09:30:00Z"}}}},
            {"attachments", QJsonArray{}}});
    };
    add("logo", "Colorier le logo en vert", "to_do", "Design", "Taya", "legal", 0);
    add("law", "Vérifier la loi concernant les olim hadashim en Israël", "to_do", "Research", "Taya", "legal", 1);
    add("shop", "J’aimerai que tu fasses un site ecommerce entier pour vendre nos nouvelles collections", "to_do", "Development", "Pierro", "developer", 8, 0, "high");
    add("research", "Connais tu Tal Benamram ?", "in_progress", "Research", "Taya", "legal", 2, 50);
    add("emerald", "Change the style to emeraude", "in_progress", "Design", "Pierro", "developer", 2, 70);
    add("seo", "Fais un SEO rapide du site monpetitparfait.fr", "in_progress", "Marketing", "Pierro", "developer", 3, 40);
    add("light", "Change the design to be more light theme", "in_progress", "Design", "Pierro", "developer", 3, 30);
    add("audit", "Réaliser un audit complet de SEO de site monpetitparfait.fr", "blocked", "Marketing", "Sira", "research", -1, 0, "high");
    add("subject", "de quoi il s’agit", "in_review", "Research", "Pierro", "developer", 0);
    add("summary", "Fais un résumé de ce que tu vois", "waiting", "Documentation", "Sira", "research", 1);
    add("leads", "J’ai besoin que tu me donnes des leads de gens voulant acheter une solution complète", "in_review", "Sales", "Navi", "finance", 1, 0, "high");
    add("logo-review", "Change le logo en vert", "in_review", "Design", "Taya", "legal", 8);
    add("done-subject", "de quoi il s’agit", "completed", "Research", "Pierro", "developer", -4, 100);
    add("done-law", "Vérifie la loi concernant les olim hadashim en Israël", "completed", "Research", "Taya", "legal", -5, 100);
    add("done-summary", "Fais un résumé de ce que tu vois", "completed", "Documentation", "Sira", "research", -6, 100);
    add("done-emerald", "Change the style to emeraude", "completed", "Design", "Pierro", "developer", -7, 100);
    add("done-report", "Préparer le rapport hebdomadaire", "completed", "Documentation", "Sira", "research", -8, 100);
    add("done-brand", "Finaliser les éléments de la marque", "completed", "Design", "Taya", "legal", -9, 100);
    add("done-launch", "Publier la page de lancement", "completed", "Development", "Pierro", "developer", -10, 100);
    add("done-plan", "Valider le plan marketing", "completed", "Marketing", "Navi", "finance", -11, 100);
    return rows;
}

struct TasksFixture {
    TasksApi remote;
    QTemporaryDir cacheDirectory;
    ApiClient api{remote.origin()};
    PhoenixClient realtime;
    SessionController session{api, realtime};
    CacheStore cache{cacheDirectory.path()};
    FeatureController features{api, session, cache};
    TasksSession account;
    TasksFixture() {
        remote.rows = taskFixtures();
        api.setSession("test-only-session", "fixture-user", false);
        api.setWorkspace("fixture-workspace");
    }
};

class TasksView final {
public:
    QTemporaryDir directory;
    QQmlEngine engine;
    QStringList warnings;
    std::unique_ptr<QObject> page;
    QQuickWindow window;
    QQuickItem* item{};
    QString failure;
    explicit TasksView(TasksFixture& fixture) {
        for (const auto& name : QDir(QStringLiteral(MOKAID_TASKS_QML_DIRECTORY)).entryList({"*.qml", "*.js"}, QDir::Files))
            QFile::copy(QStringLiteral(MOKAID_TASKS_QML_DIRECTORY) + "/" + name, directory.path() + "/" + name);
        QFile qmldir(directory.path() + "/qmldir");
        if (!qmldir.open(QIODevice::WriteOnly)) { failure = "Cannot create fixture QML module"; return; }
        qmldir.write("singleton Theme 1.0 Theme.qml\n"); qmldir.close();
        QObject::connect(&engine, &QQmlEngine::warnings, &engine, [this](const QList<QQmlError>& errors) {
            for (const auto& error : errors) warnings.append(error.toString());
        });
        engine.rootContext()->setContextProperty("features", &fixture.features);
        engine.rootContext()->setContextProperty("session", &fixture.account);
        QQmlComponent component(&engine, QUrl::fromLocalFile(directory.path() + "/TasksPage.qml"));
        page.reset(component.create()); failure = component.errorString();
        item = qobject_cast<QQuickItem*>(page.get());
        if (!item) return;
        window.setColor(QColor("#090b13")); item->setParentItem(window.contentItem()); resize(1228, 820); window.show();
    }
    ~TasksView() { if (item) item->setParentItem(nullptr); }
    void resize(int width, int height) { window.resize(width, height); if (item) item->setSize(QSizeF(width, height)); }
    QList<QQuickItem*> children() const {
        QList<QQuickItem*> result;
        if (!item) return result;
        result.append(window.contentItem());
        for (qsizetype i = 0; i < result.size(); ++i) result.append(result.at(i)->childItems());
        return result;
    }
    QQuickItem* find(const QString& name) const {
        for (auto* child : children()) if (child->objectName() == name && child->isVisible()) return child;
        return nullptr;
    }
    QPoint center(QQuickItem* control) const { return control->mapToScene(QPointF(control->width() / 2, control->height() / 2)).toPoint(); }
    void polish() {
        QCoreApplication::processEvents();
        // Render the window once so nested layouts receive normal Qt polish,
        // rather than forcing individual controls in an arbitrary order.
        window.grabWindow();
    }
    bool click(const QString& name) {
        // New delegates can exist before their RowLayout has assigned geometry.
        // Flush pending polish before deriving the actual pointer coordinates.
        polish();
        auto* control = find(name); if (!control) return false;
        QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, center(control)); return true;
    }
    bool clickOverview(const QString& name) {
        polish();
        auto* control = find(name);
        auto* scroll = find("taskOverviewScroll");
        if (!control || !scroll) return false;
        auto* content = qobject_cast<QQuickItem*>(scroll->property("contentItem").value<QObject*>());
        if (!content) return false;
        const auto offset = control->mapToItem(scroll, QPointF(0, control->height() / 2)).y() - scroll->height() / 2;
        const auto limit = qMax(0., content->property("contentHeight").toReal() - content->height());
        content->setProperty("contentY", qBound(0., content->property("contentY").toReal() + offset, limit));
        return click(name);
    }
    bool drag(const QString& cardName, const QString& destinationName) {
        auto* card = find(cardName); auto* destination = find(destinationName);
        if (!card || !destination) return false;
        // Grab the title area, avoiding the completion circle and overflow menu.
        const auto start = card->mapToScene(QPointF(card->width() * 0.45, 24)).toPoint();
        const auto end = destination->mapToScene(QPointF(destination->width() / 2, 70)).toPoint();
        QTest::mousePress(&window, Qt::LeftButton, Qt::NoModifier, start);
        for (int step = 1; step <= 12; ++step)
            QTest::mouseMove(&window, start + (end - start) * step / 12, 18);
        QTest::mouseRelease(&window, Qt::LeftButton, Qt::NoModifier, end);
        return true;
    }
    int laneCount(const QString& lane) const {
        const auto* list = find("taskLaneList_" + lane); return list ? list->property("count").toInt() : -1;
    }
    bool hasText(const QString& text) const {
        for (const auto* child : children()) if (child->isVisible() && child->property("text").toString() == text) return true;
        return false;
    }
    bool inside(const QString& name) const {
        auto* control = find(name); if (!control) return false;
        const auto point = control->mapToItem(item, QPointF());
        return point.x() >= -1 && point.y() >= -1 && point.x() + control->width() <= item->width() + 1
            && point.y() + control->height() <= item->height() + 1;
    }
    bool capture(const QString& name) {
        const auto output = qEnvironmentVariable("MOKAID_TASKS_CAPTURE_DIR");
        if (output.isEmpty()) return true;
        QDir().mkpath(output); return window.grabWindow().save(output + "/" + name + ".png");
    }
};

class TasksQmlTests final : public QObject {
    Q_OBJECT
private slots:
    void budgetExtensionRetriesWithSameIdentityAndResumesExistingRun() {
        TasksFixture fixture;
        fixture.remote.budgetStatus = 503;
        fixture.remote.updateTask("logo", {{"latest_run", QJsonObject{{"id", "budget-run"}, {"status", "waiting_for_user_input"},
            {"output", QJsonObject{{"runtime", QJsonObject{{"engine", "openai_agents"}, {"status", "waiting_for_budget"}}}}}}}});
        fixture.features.navigate("tasks"); QTRY_VERIFY(!fixture.features.busy());
        TasksView view(fixture); QVERIFY2(view.item, qPrintable(view.failure));
        QVERIFY(view.click("taskCard_logo")); QTRY_VERIFY(view.find("runtimeBudget500"));
        QVERIFY(view.clickOverview("runtimeBudget500"));
        QTRY_VERIFY(!fixture.features.busy());
        QTRY_VERIFY(view.hasText("Retry +500 credits"));
        QVERIFY(!view.find("runtimeBudget2000")->isEnabled());
        const auto firstIndex = fixture.remote.paths.indexOf("/api/tasks/logo/runtime-budget");
        QVERIFY(firstIndex >= 0);
        const auto first = fixture.remote.bodies.at(firstIndex);
        QCOMPARE(first.value("run_id").toString(), QString("budget-run"));
        QCOMPARE(first.value("additional_credits").toInt(), 500);
        QVERIFY(!QUuid(first.value("request_id").toString()).isNull());
        fixture.remote.budgetStatus = 200;
        QVERIFY(view.clickOverview("runtimeBudget500"));
        QTRY_COMPARE(fixture.remote.paths.count("/api/tasks/logo/runtime-budget"), 2);
        const auto lastIndex = fixture.remote.paths.lastIndexOf("/api/tasks/logo/runtime-budget");
        QCOMPARE(fixture.remote.bodies.at(lastIndex), first);
        QTRY_VERIFY(view.hasText("Working"));
        QVERIFY(!view.find("runtimeBudget500"));
        QVERIFY(!fixture.remote.paths.contains("/api/tasks/logo/execute-ai"));
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }
    void managedTeamProgressShowsBudgetPauseAndContributorActivity() {
        TasksFixture fixture;
        const QJsonObject runtime{{"engine", "openai_agents"}, {"status", "waiting_for_budget"},
            {"participants", QJsonArray{QJsonObject{{"agent_id", "agent-sira"}, {"name", "Sira"}, {"status", "completed"}, {"assignment", "Inspect public sources"}},
                QJsonObject{{"agent_id", "agent-navi"}, {"name", "Navi"}, {"status", "running"}, {"assignment", "Combine the findings"}}}},
            {"budget", QJsonObject{{"limit_credits", 500}, {"reserved_credits", 500}, {"used_credits", 400}, {"remaining_credits", 100}, {"estimated", true}, {"usage_complete", true}}},
            {"verification", QJsonObject{{"passed", false}, {"checks", QJsonArray{QJsonObject{{"name", "Private analytics"}, {"passed", false}, {"message", "Access is missing"}}}}}},
            {"limitations", QJsonArray{"Search Console access is missing"}}};
        fixture.remote.updateTask("logo", {{"latest_run", QJsonObject{{"id", "managed-run"}, {"status", "waiting_for_user_input"},
            {"output", QJsonObject{{"runtime", runtime}}}, {"tool_activity", QJsonArray{QJsonObject{{"id", "managed-run:1"}, {"description", "Checked public sources"}, {"status", "ok"}, {"agent_id", "agent-sira"}}}}}}});
        fixture.features.navigate("tasks"); QTRY_VERIFY(!fixture.features.busy());
        TasksView view(fixture); QVERIFY2(view.item, qPrintable(view.failure));
        QVERIFY(view.click("taskCard_logo")); QTRY_COMPARE(fixture.features.selectedId(), QString("logo"));
        QTRY_VERIFY(view.hasText("Team execution"));
        QTRY_VERIFY(view.hasText("Paused: credit limit reached"));
        QVERIFY(view.hasText("Combine the findings"));
        QVERIFY(view.hasText("Delivery needs checking"));
        QVERIFY(view.hasText("Search Console access is missing"));
        QVERIFY(view.hasText("Estimated used"));
        QCOMPARE(view.find("taskRuntimeCredit_used_credits")->property("text").toString(), QString("400"));
        QVERIFY(!view.hasText("Delivery checks passed"));
        view.resize(760, 760); view.polish();
        QVERIFY(view.capture("tasks-managed-runtime-760"));
        QVERIFY(view.click("taskTab_activity"));
        QTRY_VERIFY(view.hasText("Sira · Checked public sources"));
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }
    void managedRuntimeNeverInventsMissingCreditsOrVerification() {
        TasksFixture fixture;
        fixture.remote.updateTask("logo", {{"latest_run", QJsonObject{{"id", "managed-run"}, {"status", "running"},
            {"output", QJsonObject{{"runtime", QJsonObject{{"engine", "openai_agents"}, {"status", "running"}, {"budget", QJsonObject{}},
                {"verification", QJsonObject{{"passed", true}, {"checks", QJsonArray{}}}}}}}}}}});
        fixture.features.navigate("tasks"); QTRY_VERIFY(!fixture.features.busy());
        TasksView view(fixture); QVERIFY2(view.item, qPrintable(view.failure));
        QVERIFY(view.click("taskCard_logo")); QTRY_COMPARE(fixture.features.selectedId(), QString("logo"));
        QTRY_VERIFY(view.hasText("Delivery checks pending"));
        QCOMPARE(view.find("taskRuntimeCredit_used_credits")->property("text").toString(), QString("Unavailable"));
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }
    void referenceBoardRendersResponsiveAndOpensInspector() {
        TasksFixture fixture;
        QVERIFY(fixture.remote.server.isListening());
        fixture.features.navigate("tasks"); QTRY_VERIFY(!fixture.features.busy());
        TasksView view(fixture); QVERIFY2(view.item, qPrintable(view.failure));
        QTRY_COMPARE(view.laneCount("todo"), 3);
        QCOMPARE(view.laneCount("doing"), 4); QCOMPARE(view.laneCount("review"), 5); QCOMPARE(view.laneCount("done"), 8);
        QVERIFY(view.hasText("Design")); QVERIFY(view.hasText("Research"));
        QVERIFY(view.inside("tasksSearch")); QVERIFY(view.inside("tasksNewTask"));
        QTest::qWait(100); QVERIFY(view.capture("tasks-board-1228"));
        QVERIFY(view.click("taskCard_logo")); QTRY_COMPARE(fixture.features.selectedId(), QString("logo"));
        QTRY_VERIFY(view.inside("taskInspectorClose"));
        QTRY_VERIFY(view.hasText("Comprendre le besoin"));
        QTest::qWait(150); QVERIFY(view.capture("tasks-inspector-1228"));
        for (int step = 0; step < 18; ++step) {
            QTest::keyClick(&view.window, Qt::Key_Tab);
            QVERIFY(!view.find("tasksNewTask")->hasActiveFocus());
            QVERIFY(!view.find("taskCard_logo")->hasActiveFocus());
        }
        // TextArea accepts literal indentation tabs; clear that fixture input
        // before the visual captures so it does not look like an unsent draft.
        QVERIFY(QMetaObject::invokeMethod(view.page.get(), "setCommentDraft", Q_ARG(QVariant, QString("logo")), Q_ARG(QVariant, QString())));
        QVERIFY(view.click("taskTab_activity"));
        view.find("taskTab_activity")->forceActiveFocus();
        QTRY_VERIFY(view.hasText("Le brief est prêt. Je m’occupe de la première version."));
        QVERIFY(view.capture("tasks-activity-1228"));
        QTest::keyClick(&view.window, Qt::Key_Escape); QTRY_VERIFY(fixture.features.selectedId().isEmpty());
        QTRY_VERIFY(view.find("taskCard_logo")->hasActiveFocus());
        view.resize(760, 760); QTest::qWait(80);
        QVERIFY(view.inside("tasksSearch")); QVERIFY(view.inside("tasksNewTask"));
        QVERIFY(view.capture("tasks-board-760"));
        QVERIFY(view.click("taskCard_logo")); QTRY_COMPARE(fixture.features.selectedId(), QString("logo"));
        QTRY_VERIFY(view.inside("taskInspectorClose"));
        QTest::qWait(150); QVERIFY(view.capture("tasks-inspector-760"));
        QVERIFY(view.click("taskInspectorClose")); QTRY_VERIFY(fixture.features.selectedId().isEmpty());
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }
    void mouseDragPersistsStatusWithoutOpeningTask() {
        TasksFixture fixture;
        fixture.features.navigate("tasks"); QTRY_VERIFY(!fixture.features.busy());
        TasksView view(fixture); QVERIFY2(view.item, qPrintable(view.failure));
        QTRY_COMPARE(view.laneCount("todo"), 3);
        QVERIFY(view.drag("taskCard_logo", "taskDrop_doing"));
        QTRY_COMPARE(fixture.remote.patchCount(), 1);
        QCOMPARE(fixture.remote.lastPatch(), QJsonObject({{"status", "in_progress"}}));
        QTRY_COMPARE(view.laneCount("todo"), 2); QTRY_COMPARE(view.laneCount("doing"), 5);
        QVERIFY(fixture.features.selectedId().isEmpty());
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }
    void droppingIntoSameColumnDoesNotMutateOrOpenTask() {
        TasksFixture fixture;
        fixture.features.navigate("tasks"); QTRY_VERIFY(!fixture.features.busy());
        TasksView view(fixture); QVERIFY2(view.item, qPrintable(view.failure));
        QTRY_COMPARE(view.laneCount("todo"), 3);
        QVERIFY(view.drag("taskCard_logo", "taskDrop_todo"));
        QTest::qWait(50);
        QCOMPARE(fixture.remote.patchCount(), 0); QCOMPARE(view.laneCount("todo"), 3);
        QVERIFY(fixture.features.selectedId().isEmpty());
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }
    void compactBoardAutoScrollsWhileDraggingToLastColumn() {
        TasksFixture fixture;
        fixture.features.navigate("tasks"); QTRY_VERIFY(!fixture.features.busy());
        TasksView view(fixture); QVERIFY2(view.item, qPrintable(view.failure));
        view.resize(760, 760);
        QTRY_COMPARE(view.laneCount("todo"), 3);
        view.polish();
        auto* board = view.find("task-board"); auto* card = view.find("taskCard_logo"); auto* destination = view.find("taskDrop_done");
        QVERIFY(board); QVERIFY(card); QVERIFY(destination);
        const auto start = card->mapToScene(QPointF(card->width() * 0.45, 24)).toPoint();
        const auto edge = board->mapToScene(QPointF(board->width() - 10, 70)).toPoint();
        QTest::mousePress(&view.window, Qt::LeftButton, Qt::NoModifier, start);
        for (int step = 1; step <= 16; ++step) QTest::mouseMove(&view.window, start + (edge - start) * step / 16, 18);
        QTRY_VERIFY(destination->mapToScene(QPointF(destination->width(), 0)).x() <= view.window.width() + 1);
        const auto end = destination->mapToScene(QPointF(destination->width() / 2, 70)).toPoint();
        QTest::mouseMove(&view.window, end, 18); QTest::mouseRelease(&view.window, Qt::LeftButton, Qt::NoModifier, end);
        QTRY_COMPARE(fixture.remote.patchCount(), 1);
        QCOMPARE(fixture.remote.lastPatch(), QJsonObject({{"status", "completed"}}));
        QTRY_COMPARE(view.laneCount("done"), 9); QCOMPARE(view.laneCount("todo"), 2);
        QVERIFY(fixture.features.selectedId().isEmpty());
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }
    void escapeCancelsDragAndNextDragStillWorks() {
        TasksFixture fixture;
        fixture.features.navigate("tasks"); QTRY_VERIFY(!fixture.features.busy());
        TasksView view(fixture); QVERIFY2(view.item, qPrintable(view.failure));
        QTRY_COMPARE(view.laneCount("todo"), 3); view.polish();
        auto* card = view.find("taskCard_logo"); auto* destination = view.find("taskDrop_doing");
        QVERIFY(card); QVERIFY(destination);
        const auto start = card->mapToScene(QPointF(card->width() * 0.45, 24)).toPoint();
        const auto end = destination->mapToScene(QPointF(destination->width() / 2, 70)).toPoint();
        QTest::mousePress(&view.window, Qt::LeftButton, Qt::NoModifier, start);
        for (int step = 1; step <= 12; ++step) QTest::mouseMove(&view.window, start + (end - start) * step / 12, 18);
        QTRY_VERIFY(card->property("dragging").toBool());
        QTest::keyClick(&view.window, Qt::Key_Escape);
        QTest::mouseRelease(&view.window, Qt::LeftButton, Qt::NoModifier, end);
        QTRY_VERIFY(!card->property("dragging").toBool());
        QCOMPARE(fixture.remote.patchCount(), 0); QCOMPARE(view.laneCount("todo"), 3);
        QVERIFY(fixture.features.selectedId().isEmpty());
        QVERIFY(view.drag("taskCard_logo", "taskDrop_doing"));
        QTRY_COMPARE(fixture.remote.patchCount(), 1); QTRY_COMPARE(view.laneCount("doing"), 5);
        QVERIFY(fixture.features.selectedId().isEmpty());
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }
    void failedMouseDropKeepsOriginalColumnAndAllowsRetry() {
        TasksFixture fixture; fixture.remote.patchStatus = 422;
        fixture.features.navigate("tasks"); QTRY_VERIFY(!fixture.features.busy());
        TasksView view(fixture); QVERIFY2(view.item, qPrintable(view.failure));
        QTRY_COMPARE(view.laneCount("todo"), 3);
        QVERIFY(view.drag("taskCard_logo", "taskDrop_doing"));
        QTRY_COMPARE(fixture.remote.patchCount(), 1); QTRY_VERIFY(!fixture.features.error().isEmpty());
        QCOMPARE(view.laneCount("todo"), 3); QCOMPARE(view.laneCount("doing"), 4);
        QVERIFY(fixture.features.selectedId().isEmpty());
        fixture.remote.patchStatus = 200;
        QVERIFY(view.drag("taskCard_logo", "taskDrop_doing"));
        QTRY_COMPARE(fixture.remote.patchCount(), 2); QTRY_COMPARE(view.laneCount("doing"), 5);
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }
    void cardMenuProvidesKeyboardAlternativeToDrag() {
        TasksFixture fixture;
        fixture.features.navigate("tasks"); QTRY_VERIFY(!fixture.features.busy());
        TasksView view(fixture); QVERIFY2(view.item, qPrintable(view.failure));
        QTRY_VERIFY(view.find("taskCardMenu_logo"));
        QVERIFY(view.click("taskCardMenu_logo")); QTRY_VERIFY(view.find("taskMoveDoing"));
        QTest::keyClick(&view.window, Qt::Key_Down); // Open task.
        QTest::keyClick(&view.window, Qt::Key_Down); // Move to Todo; separator is skipped.
        QTest::keyClick(&view.window, Qt::Key_Down); // Move to In progress.
        QTRY_VERIFY(view.find("taskMoveDoing")->hasActiveFocus());
        QTest::keyClick(&view.window, Qt::Key_Return);
        QTRY_COMPARE(fixture.remote.patchCount(), 1);
        QCOMPARE(fixture.remote.lastPatch(), QJsonObject({{"status", "in_progress"}}));
        QTRY_COMPARE(view.laneCount("doing"), 5);
        QVERIFY(fixture.features.selectedId().isEmpty());
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }
    void searchAndOwnershipFiltersOnlyShowMatchingTasks() {
        TasksFixture fixture;
        fixture.features.navigate("tasks"); QTRY_VERIFY(!fixture.features.busy());
        TasksView view(fixture); QVERIFY2(view.item, qPrintable(view.failure));
        QTRY_COMPARE(view.laneCount("todo"), 3);
        QVERIFY(view.click("tasksFilter-mine"));
        QTRY_COMPARE(view.laneCount("todo"), 3); QCOMPARE(view.laneCount("doing"), 4); QCOMPARE(view.laneCount("review"), 1); QCOMPARE(view.laneCount("done"), 0);
        QVERIFY(view.click("tasksFilter-assigned"));
        QTRY_COMPARE(view.laneCount("doing"), 3); QCOMPARE(view.laneCount("review"), 0);
        QVERIFY(view.click("tasksFilter-overdue"));
        QTRY_COMPARE(view.laneCount("review"), 1); QCOMPARE(view.laneCount("todo"), 0); QCOMPARE(view.laneCount("done"), 0);
        QVERIFY(view.click("tasksFilter-all"));
        QVERIFY(view.click("tasksSearch")); for (const auto key : QByteArray("ecommerce")) QTest::keyClick(&view.window, key);
        QTRY_COMPARE(view.laneCount("todo"), 1); QCOMPARE(view.laneCount("doing"), 0); QCOMPARE(view.laneCount("review"), 0); QCOMPARE(view.laneCount("done"), 0);
        QVERIFY(view.find("taskCard_shop"));
        for (const auto key : QByteArray(" no result")) QTest::keyClick(&view.window, key);
        QTRY_VERIFY(view.hasText("No tasks match your filters"));
        QVERIFY(!view.find("task-board"));
        QCOMPARE(fixture.features.allRecords().size(), 20);
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }
    void inspectorStatusCanBeChangedWithKeyboard() {
        TasksFixture fixture;
        fixture.features.navigate("tasks"); QTRY_VERIFY(!fixture.features.busy());
        TasksView view(fixture); QVERIFY2(view.item, qPrintable(view.failure));
        QTRY_VERIFY(view.find("taskCard_logo"));
        QVERIFY(view.click("taskCard_logo")); QTRY_COMPARE(fixture.features.selectedId(), QString("logo"));
        QTRY_VERIFY(view.find("taskStatusButton")); QVERIFY(view.click("taskStatusButton"));
        QTRY_VERIFY(view.find("taskStatus_to_do"));
        QTest::keyClick(&view.window, Qt::Key_Down);
        QTRY_VERIFY(view.find("taskStatus_to_do")->hasActiveFocus());
        QTest::keyClick(&view.window, Qt::Key_Down);
        QTRY_VERIFY(view.find("taskStatus_in_progress")->hasActiveFocus());
        QTest::keyClick(&view.window, Qt::Key_Return);
        QTRY_COMPARE(fixture.remote.patchCount(), 1);
        QCOMPARE(fixture.remote.lastPatch(), QJsonObject({{"status", "in_progress"}}));
        QTRY_COMPARE(fixture.features.selectedRecord().value("status").toString(), QString("in_progress"));
        QCOMPARE(fixture.features.selectedId(), QString("logo"));
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }
    void commentDraftSurvivesCloseAndFailureThenClearsAfterSend() {
        TasksFixture fixture; fixture.remote.commentStatus = 422;
        fixture.features.navigate("tasks"); QTRY_VERIFY(!fixture.features.busy());
        TasksView view(fixture); QVERIFY2(view.item, qPrintable(view.failure));
        QTRY_VERIFY(view.find("taskCard_logo"));
        QVERIFY(view.click("taskCard_logo")); QTRY_COMPARE(fixture.features.selectedId(), QString("logo"));
        QTRY_VERIFY(view.find("taskCommentComposer"));
        QVERIFY(view.click("taskCommentComposer"));
        for (const auto key : QByteArray("Please keep the green option.")) QTest::keyClick(&view.window, key);
        QCOMPARE(view.find("taskCommentComposer")->property("text").toString(), QString("Please keep the green option."));
        QVERIFY(view.click("taskInspectorClose")); QTRY_VERIFY(fixture.features.selectedId().isEmpty());
        QVERIFY(view.click("taskCard_law")); QTRY_COMPARE(fixture.features.selectedId(), QString("law"));
        QTRY_VERIFY(!fixture.features.busy());
        QTRY_VERIFY(view.find("taskCommentComposer"));
        QCOMPARE(view.find("taskCommentComposer")->property("text").toString(), QString());
        QVERIFY(view.click("taskCommentComposer"));
        for (const auto key : QByteArray("Separate legal draft.")) QTest::keyClick(&view.window, key);
        QVERIFY(view.click("taskInspectorClose")); QTRY_VERIFY(fixture.features.selectedId().isEmpty());
        QVERIFY(view.click("taskCard_logo")); QTRY_COMPARE(fixture.features.selectedId(), QString("logo"));
        QTRY_VERIFY(!fixture.features.busy());
        QTRY_COMPARE(view.find("taskCommentComposer")->property("text").toString(), QString("Please keep the green option."));
        QVERIFY(view.click("taskQuick_comment")); QTRY_VERIFY(!fixture.features.error().isEmpty());
        QCOMPARE(view.find("taskCommentComposer")->property("text").toString(), QString("Please keep the green option."));
        fixture.remote.commentStatus = 200;
        QVERIFY(view.click("taskQuick_comment"));
        QTRY_COMPARE(fixture.remote.methods.count("POST"), 2);
        QTRY_COMPARE(view.find("taskCommentComposer")->property("text").toString(), QString());
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }
    void listViewAndCompletionControlWorkWithoutOpeningInspector() {
        TasksFixture fixture;
        fixture.features.navigate("tasks"); QTRY_VERIFY(!fixture.features.busy());
        TasksView view(fixture); QVERIFY2(view.item, qPrintable(view.failure));
        QTRY_VERIFY(view.find("tasksViewMode"));
        QVERIFY(view.click("tasksViewMode"));
        QTest::keyClick(&view.window, Qt::Key_End); QTest::keyClick(&view.window, Qt::Key_Return);
        QTRY_COMPARE(view.page->property("viewMode").toString(), QString("list"));
        QTRY_VERIFY(view.find("tasksList"));
        QCOMPARE(view.find("tasksList")->property("count").toInt(), 20);
        QVERIFY(view.click("taskComplete_logo")); QTRY_COMPARE(fixture.remote.patchCount(), 1);
        QCOMPARE(fixture.remote.lastPatch(), QJsonObject({{"status", "completed"}}));
        QVERIFY(fixture.features.selectedId().isEmpty());
        view.resize(760, 760); QTest::qWait(50); QVERIFY(view.capture("tasks-list-760"));
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }
    void completedResponseCanBeAcceptedInlineWithoutApprovalForm() {
        TasksFixture fixture;
        fixture.remote.updateTask("done-subject", {{"description", "Deliver the requested summary."},
            {"latest_run", QJsonObject{{"id", "run-summary"}, {"status", "completed"},
                {"output", QJsonObject{{"summary", "The finished summary is ready."}}}}}});
        fixture.features.navigate("tasks"); QTRY_VERIFY(!fixture.features.busy());
        TasksView view(fixture); QVERIFY2(view.item, qPrintable(view.failure));
        QSignalSpy actions(view.page.get(), SIGNAL(actionRequested(QVariant))); QVERIFY(actions.isValid());
        QVERIFY(view.click("taskCard_done-subject")); QTRY_COMPARE(fixture.features.selectedId(), QString("done-subject"));
        QTRY_VERIFY(!fixture.features.busy());
        QTRY_VERIFY(view.hasText("The finished summary is ready."));
        QTRY_VERIFY(view.find("taskFeedbackGood"));
        QVERIFY(!view.find("taskQuick_approve")); QVERIFY(!view.hasText("Review action"));
        for (const auto& action : fixture.features.actions()) QVERIFY(action.toMap().value("id") != "approve");
        QTest::qWait(100); QVERIFY(view.capture("tasks-response-feedback-1228"));
        QVERIFY(view.clickOverview("taskFeedbackGood"));
        QTRY_COMPARE(fixture.remote.feedbackCount(), 1);
        QCOMPARE(fixture.remote.lastFeedback(), QJsonObject({{"rating", "good"}, {"run_id", "run-summary"}}));
        QVERIFY(fixture.remote.paths.contains("/api/tasks/done-subject/feedback"));
        QTRY_VERIFY(view.hasText("Accepted"));
        QVERIFY(!view.find("taskFeedbackGood")->isEnabled());
        QCOMPARE(actions.size(), 0);
        QCOMPARE(fixture.remote.patchCount(), 0);
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }
    void pendingActionRequiresAnImprovementPromptAndContinuesSameTask() {
        TasksFixture fixture; fixture.remote.feedbackDelay = 250;
        fixture.remote.updateTask("seo", {{"description", "Prepare a useful SEO report."},
            {"status", "waiting"}, {"pending_approval", QJsonObject{{"id", "old-approval"},
                {"tool_name", "send_email"}}},
            {"latest_run", QJsonObject{{"id", "run-seo"}, {"status", "waiting_for_approval"}}}});
        fixture.features.navigate("tasks"); QTRY_VERIFY(!fixture.features.busy());
        TasksView view(fixture); QVERIFY2(view.item, qPrintable(view.failure));
        QSignalSpy actions(view.page.get(), SIGNAL(actionRequested(QVariant))); QVERIFY(actions.isValid());
        QTRY_VERIFY(view.find("taskCard_seo"));
        QVERIFY(view.click("taskCard_seo")); QTRY_COMPARE(fixture.features.selectedId(), QString("seo"));
        QTRY_VERIFY(!fixture.features.busy());
        QTRY_VERIFY(view.find("taskFeedbackImprove"));
        QVERIFY(!view.find("taskFeedbackGood")->isEnabled());
        QVERIFY(!view.find("taskQuick_approve")); QVERIFY(!view.find("writeSeoReport"));
        QVERIFY(!view.hasText("Review action")); QVERIFY(!view.hasText("Approval request ID"));
        QVERIFY(view.clickOverview("taskFeedbackImprove")); QTRY_VERIFY(view.find("taskFeedbackPrompt"));
        QTRY_VERIFY(view.find("taskFeedbackContinue")); QVERIFY(!view.find("taskFeedbackContinue")->isEnabled());
        QVERIFY(view.clickOverview("taskFeedbackPrompt"));
        QTest::keyClick(&view.window, Qt::Key_Space); QTest::keyClick(&view.window, Qt::Key_Space);
        QVERIFY(!view.find("taskFeedbackContinue")->isEnabled());
        QCOMPARE(fixture.remote.feedbackCount(), 0);
        for (const auto key : QByteArray("Finish the report with concrete recommendations.  ")) QTest::keyClick(&view.window, key);
        QTRY_VERIFY(view.find("taskFeedbackContinue")->isEnabled());
        QVERIFY(view.clickOverview("taskFeedbackContinue"));
        QTRY_COMPARE(fixture.remote.feedbackCount(), 1);
        QCOMPARE(fixture.remote.lastFeedback(), QJsonObject({{"rating", "needs_improvement"},
            {"prompt", "Finish the report with concrete recommendations."}, {"run_id", "run-seo"}}));
        QVERIFY(fixture.remote.paths.contains("/api/tasks/seo/feedback"));
        QVERIFY(view.click("taskInspectorClose")); QTRY_VERIFY(fixture.features.selectedId().isEmpty());
        QVERIFY(view.click("taskCard_logo")); QTRY_COMPARE(fixture.features.selectedId(), QString("logo"));
        QTRY_VERIFY(!fixture.features.busy());
        QTest::qWait(300);
        QCOMPARE(fixture.remote.feedbackCount(), 1);
        QVERIFY(!fixture.remote.paths.contains("/api/tasks/logo/feedback"));
        QVERIFY(!fixture.remote.paths.contains("/api/tasks/seo/stop-ai"));
        QVERIFY(!fixture.remote.paths.contains("/api/tasks/seo/execute-ai"));
        QVERIFY(!fixture.remote.paths.contains("/api/tasks/logo/execute-ai"));
        QCOMPARE(actions.size(), 0);
        QCOMPARE(fixture.features.selectedId(), QString("logo"));
        QVERIFY(!view.page->property("hasDrafts").toBool());
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }
    void improvementDraftIsKeptPerTaskAcrossCloseAndFailureThenClearsOnSuccess() {
        TasksFixture fixture; fixture.remote.feedbackStatus = 422;
        fixture.remote.updateTask("subject", {{"description", "Summarize the subject."},
            {"latest_run", QJsonObject{{"id", "run-subject"}, {"status", "completed"}, {"output", QJsonObject{{"summary", "A short summary."}}}}}});
        fixture.remote.updateTask("leads", {{"description", "Find suitable leads."},
            {"latest_run", QJsonObject{{"id", "run-leads"}, {"status", "completed"}, {"output", QJsonObject{{"summary", "An initial set of leads."}}}}}});
        fixture.features.navigate("tasks"); QTRY_VERIFY(!fixture.features.busy());
        TasksView view(fixture); QVERIFY2(view.item, qPrintable(view.failure));
        QVERIFY(view.click("taskCard_subject")); QTRY_COMPARE(fixture.features.selectedId(), QString("subject"));
        QTRY_VERIFY(!fixture.features.busy());
        QVERIFY(view.clickOverview("taskFeedbackImprove")); QTRY_VERIFY(view.find("taskFeedbackPrompt"));
        QVERIFY(view.clickOverview("taskFeedbackPrompt"));
        for (const auto key : QByteArray("Explain the subject more clearly.")) QTest::keyClick(&view.window, key);
        QVERIFY(view.page->property("hasDrafts").toBool());
        QTest::qWait(100); QVERIFY(view.capture("tasks-improvement-prompt-1228"));
        view.resize(760, 760); QTest::qWait(100);
        QVERIFY(view.clickOverview("taskFeedbackPrompt"));
        QVERIFY(view.capture("tasks-improvement-prompt-760"));
        view.resize(1228, 820); view.polish();
        QVERIFY(view.click("taskInspectorClose")); QTRY_VERIFY(fixture.features.selectedId().isEmpty());
        QVERIFY(view.click("taskCard_leads")); QTRY_COMPARE(fixture.features.selectedId(), QString("leads"));
        QTRY_VERIFY(!fixture.features.busy());
        QVERIFY(view.clickOverview("taskFeedbackImprove")); QTRY_VERIFY(view.find("taskFeedbackPrompt"));
        QCOMPARE(view.find("taskFeedbackPrompt")->property("text").toString(), QString());
        QVERIFY(view.clickOverview("taskFeedbackPrompt"));
        for (const auto key : QByteArray("Include a contact for each lead.")) QTest::keyClick(&view.window, key);
        QVERIFY(view.click("taskInspectorClose")); QTRY_VERIFY(fixture.features.selectedId().isEmpty());
        QVERIFY(view.click("taskCard_subject")); QTRY_COMPARE(fixture.features.selectedId(), QString("subject"));
        QTRY_VERIFY(!fixture.features.busy());
        QTRY_VERIFY(view.find("taskFeedbackPrompt"));
        QCOMPARE(view.find("taskFeedbackPrompt")->property("text").toString(), QString("Explain the subject more clearly."));
        QVERIFY(view.clickOverview("taskFeedbackContinue")); QTRY_COMPARE(fixture.remote.feedbackCount(), 1);
        QTRY_VERIFY(view.hasText("The feedback could not be saved. Try again."));
        QCOMPARE(view.find("taskFeedbackPrompt")->property("text").toString(), QString("Explain the subject more clearly."));
        QCOMPARE(fixture.remote.lastFeedback(), QJsonObject({{"rating", "needs_improvement"},
            {"prompt", "Explain the subject more clearly."}, {"run_id", "run-subject"}}));
        fixture.remote.feedbackStatus = 200;
        QVERIFY(view.clickOverview("taskFeedbackContinue")); QTRY_COMPARE(fixture.remote.feedbackCount(), 2);
        QTRY_VERIFY(!fixture.features.busy());
        const auto drafts = view.page->property("improvementDrafts").value<QJSValue>().toVariant().toMap();
        QCOMPARE(drafts.value("subject").toString(), QString());
        QCOMPARE(drafts.value("leads").toString(), QString("Include a contact for each lead."));
        QVERIFY(view.click("taskInspectorClose")); QTRY_VERIFY(fixture.features.selectedId().isEmpty());
        QVERIFY(view.click("taskCard_leads")); QTRY_COMPARE(fixture.features.selectedId(), QString("leads"));
        QTRY_VERIFY(!fixture.features.busy()); QTRY_VERIFY(view.find("taskFeedbackPrompt"));
        QCOMPARE(view.find("taskFeedbackPrompt")->property("text").toString(), QString("Include a contact for each lead."));
        QVERIFY(!fixture.remote.paths.contains("/api/tasks/leads/feedback"));
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }
    void feedbackOnlyAppearsWhenTheAgentCanReceiveIt_data() {
        QTest::addColumn<QString>("taskStatus");
        QTest::addColumn<QString>("runStatus");
        QTest::addColumn<QString>("agentKind");
        QTest::addColumn<bool>("expected");
        QTest::newRow("completed") << QString("completed") << QString("completed") << QString("ai") << true;
        QTest::newRow("in review") << QString("in_review") << QString("completed") << QString("ai") << true;
        QTest::newRow("waiting for approval") << QString("waiting") << QString("waiting_for_approval") << QString("ai") << true;
        QTest::newRow("needs input") << QString("waiting") << QString("needs_input") << QString("ai") << true;
        QTest::newRow("failed") << QString("blocked") << QString("failed") << QString("ai") << true;
        QTest::newRow("running") << QString("in_progress") << QString("running") << QString("ai") << false;
        QTest::newRow("queued") << QString("in_progress") << QString("queued") << QString("ai") << false;
        QTest::newRow("human") << QString("completed") << QString("completed") << QString("human_linked") << false;
    }
    void feedbackOnlyAppearsWhenTheAgentCanReceiveIt() {
        QFETCH(QString, taskStatus); QFETCH(QString, runStatus); QFETCH(QString, agentKind); QFETCH(bool, expected);
        TasksFixture fixture;
        fixture.remote.updateTask("subject", {{"status", taskStatus}, {"assigned_agent_kind", agentKind},
            {"latest_run", QJsonObject{{"id", "run-subject"}, {"status", runStatus}}}});
        fixture.features.navigate("tasks"); QTRY_VERIFY(!fixture.features.busy());
        TasksView view(fixture); QVERIFY2(view.item, qPrintable(view.failure));
        fixture.features.select("subject"); QTRY_COMPARE(fixture.features.selectedId(), QString("subject"));
        QTRY_VERIFY(!fixture.features.busy()); view.polish();
        QCOMPARE(view.find("taskFeedbackImprove") != nullptr, expected);
        QVERIFY(!view.find("taskQuick_approve"));
        QCOMPARE(fixture.remote.feedbackCount(), 0);
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }
    void pdfExportDoesNotAskForApprovalOrPrematureResponseFeedback() {
        TasksFixture fixture;
        fixture.remote.updateTask("subject", {{"status", "waiting"},
            {"pending_approval", QJsonObject{{"id", "legacy-pdf-approval"}, {"tool_name", "export_pdf"}}},
            {"latest_run", QJsonObject{{"id", "run-pdf"}, {"status", "waiting_for_approval"},
                {"output", QJsonObject{{"summary", "The report is being exported."}}}}}});
        fixture.features.navigate("tasks"); QTRY_VERIFY(!fixture.features.busy());
        TasksView view(fixture); QVERIFY2(view.item, qPrintable(view.failure));
        fixture.features.select("subject"); QTRY_COMPARE(fixture.features.selectedId(), QString("subject"));
        QTRY_VERIFY(!fixture.features.busy()); view.polish();
        QVERIFY(!view.find("taskQuick_approve")); QVERIFY(!view.find("taskFeedbackGood"));
        QVERIFY(!view.find("taskFeedbackImprove")); QVERIFY(!view.find("taskQuick_run"));
        QVERIFY(!view.find("taskDecisionAllow")); QVERIFY(!view.find("taskDecisionDecline"));
        QVERIFY(!view.find("taskDeliveryHtml")); QVERIFY(!view.find("taskDeliveryWebapp"));
        QVERIFY(view.hasText("Exporting PDF"));
        QCOMPARE(fixture.remote.feedbackCount(), 0);
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }
    void nonPdfDecisionIsAnsweredInlineWithoutTechnicalApprovalForm_data() {
        QTest::addColumn<QString>("buttonName");
        QTest::addColumn<QString>("decision");
        QTest::newRow("allow") << QString("taskDecisionAllow") << QString("approved");
        QTest::newRow("decline") << QString("taskDecisionDecline") << QString("rejected");
    }
    void nonPdfDecisionIsAnsweredInlineWithoutTechnicalApprovalForm() {
        QFETCH(QString, buttonName); QFETCH(QString, decision);
        TasksFixture fixture;
        fixture.remote.updateTask("subject", {{"status", "waiting"},
            {"description", "Prepare the requested message."},
            {"pending_approval", QJsonObject{{"id", "fixture-approval"}, {"tool_name", "send_email"},
                {"proposed_action", "Send the prepared message to the selected recipient."}}},
            {"latest_run", QJsonObject{{"id", "run-message"}, {"status", "waiting_for_approval"}}}});
        fixture.features.navigate("tasks"); QTRY_VERIFY(!fixture.features.busy());
        TasksView view(fixture); QVERIFY2(view.item, qPrintable(view.failure));
        QSignalSpy actions(view.page.get(), SIGNAL(actionRequested(QVariant))); QVERIFY(actions.isValid());
        fixture.features.select("subject"); QTRY_COMPARE(fixture.features.selectedId(), QString("subject"));
        QTRY_VERIFY(!fixture.features.busy());
        QTRY_VERIFY(view.find(buttonName));
        QVERIFY(!view.find("taskQuick_approve")); QVERIFY(!view.hasText("Review action"));
        QVERIFY(!view.hasText("Approval request ID")); QVERIFY(!view.hasText("Approved parameters"));
        QVERIFY(view.clickOverview(buttonName));
        const auto path = QString("/api/tasks/subject/approve-action");
        QTRY_COMPARE(fixture.remote.paths.count(path), 1);
        const auto request = fixture.remote.paths.indexOf(path);
        QCOMPARE(fixture.remote.methods.at(request), QString("POST"));
        QCOMPARE(fixture.remote.bodies.at(request), QJsonObject({{"approval_request_id", "fixture-approval"}, {"decision", decision}}));
        QCOMPARE(actions.size(), 0);
        QCOMPARE(fixture.remote.feedbackCount(), 0);
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }
    void emptyWorkspaceKeepsCreationAvailable() {
        TasksFixture fixture; fixture.remote.rows = {};
        fixture.features.navigate("tasks"); QTRY_VERIFY(!fixture.features.busy());
        TasksView view(fixture); QVERIFY2(view.item, qPrintable(view.failure));
        QTRY_VERIFY(view.find("tasksNewTask"));
        QVERIFY(view.inside("tasksNewTask"));
        QSignalSpy actions(view.page.get(), SIGNAL(actionRequested(QVariant)));
        QVERIFY(actions.isValid()); QVERIFY(view.click("tasksNewTask")); QTRY_COMPARE(actions.size(), 1);
        QCOMPARE(actions.first().first().toMap().value("id").toString(), QString("create"));
        QVERIFY(view.capture("tasks-empty-1228"));
        QVERIFY2(view.warnings.isEmpty(), qPrintable(view.warnings.join('\n')));
    }
};

int main(int argc, char** argv) {
    qputenv("QT_QPA_PLATFORM", "offscreen");
    QQuickWindow::setGraphicsApi(QSGRendererInterface::Software); QQuickStyle::setStyle("Basic");
    QGuiApplication app(argc, argv);
    QTemporaryDir settingsDirectory;
    QCoreApplication::setOrganizationName("MokaidTests"); QCoreApplication::setApplicationName("TasksQml");
    QSettings::setDefaultFormat(QSettings::IniFormat);
    QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, settingsDirectory.path());
    QFontDatabase::addApplicationFont(QStringLiteral(MOKAID_TASKS_QML_DIRECTORY) + "/../assets/fonts/Manrope.ttf");
    TasksQmlTests tests; return QTest::qExec(&tests, argc, argv);
}
#include "tasks_qml_tests.moc"
