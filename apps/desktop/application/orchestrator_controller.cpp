#include <mokaid/application/orchestrator_controller.hpp>
#include <QDateTime>
#include <QJsonDocument>
#include <QRegularExpression>
#include <QUuid>
#include <algorithm>

namespace mokaid::desktop {
namespace {
bool identifier(const QString& id) {
    static const QRegularExpression pattern("^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$");
    return pattern.match(id).hasMatch();
}
int matchCount(const QRegularExpression& pattern, const QString& text) {
    int count = 0;
    auto matches = pattern.globalMatch(text);
    while (matches.hasNext()) { matches.next(); ++count; }
    return count;
}
bool asksPermission(const QString& text) {
    static const QRegularExpression pattern(
        "\\b(veux-tu|voulez-vous|souhaitez-vous|tu veux que|want me to|shall i|should i|do you want|would you like|"
        "prépare cette mission|prepare this mission)\\b",
        QRegularExpression::CaseInsensitiveOption);
    return pattern.match(text).hasMatch();
}
bool affirmative(const QString& text) {
    static const QRegularExpression pattern(
        "^\\s*(oui|ouais|yes|yeah|ok|okay|d'accord|dac|vas-y|vas y|go|lance|fais-le|fais le|parfait|sure|yep)\\s*[!.]*\\s*$",
        QRegularExpression::CaseInsensitiveOption);
    return pattern.match(text).hasMatch();
}
bool workRequest(const QString& text) {
    if (affirmative(text)) return false;
    static const QRegularExpression status(
        "\\b(status|progress|où en|ou en est|how (?:is|are)|what(?:'s| is) the status)\\b",
        QRegularExpression::CaseInsensitiveOption);
    if (status.match(text).hasMatch()) return false;
    static const QRegularExpression work(
        "\\b(check|audit|analy\\w*|research|write|create|build|compare|seo|vérifi\\w*|analys\\w*|recherch\\w*|"
        "rédig\\w*|crée\\w*|créé\\w*|fais|prépar\\w*|prepare|find|cherche\\w*|regard\\w*|site|website)\\b",
        QRegularExpression::CaseInsensitiveOption);
    return work.match(text).hasMatch();
}
QString dropPermissionQuestions(const QString& text) {
    if (!asksPermission(text)) return text;
    static const QRegularExpression sentence("[^.!?]+[.!?]+|[^.!?]+$");
    QStringList kept;
    auto match = sentence.globalMatch(text);
    while (match.hasNext()) {
        const auto part = match.next().captured().trimmed();
        if (part.isEmpty() || asksPermission(part)) continue;
        kept.append(part);
    }
    return kept.join(QStringLiteral(" ")).trimmed();
}
}
OrchestratorController::OrchestratorController(ApiClient& api, SessionController& session,
        PhoenixClient& realtime, CacheStore& cache, MissionController& mission, QObject* parent)
    : QObject(parent), api_(api), session_(session), cache_(cache), mission_(mission),
      apiGeneration_(api.context().generation) {
    refreshTimer_.setInterval(20000);
    eventTimer_.setSingleShot(true); eventTimer_.setInterval(250);
    connect(&refreshTimer_, &QTimer::timeout, this, &OrchestratorController::refresh);
    connect(&eventTimer_, &QTimer::timeout, this, &OrchestratorController::refresh);
    connect(&session_, &SessionController::changed, this, &OrchestratorController::contextChanged);
    connect(&session_, &SessionController::workspaceChanged, this, &OrchestratorController::contextChanged);
    connect(&session_, &SessionController::cleared, this, &OrchestratorController::contextChanged);
    connect(&api_, &ApiClient::onlineChanged, this, [this] { contextChanged(); if (ready()) refresh(); });
    connect(&realtime, &PhoenixClient::rejoined, this, &OrchestratorController::refresh);
    connect(&realtime, &PhoenixClient::eventReceived, this,
        [this](const QString& topic, const QString& event, const QJsonObject&) {
            if (ready() && topic == "workspace:" + QString::fromStdString(api_.context().workspace_id)
                && (event.startsWith("task.") || event.startsWith("ai.") || event.startsWith("drive."))) eventTimer_.start();
        });
    connect(&mission_, &MissionController::changed, this, &OrchestratorController::syncAssignment);
    connect(&mission_, &MissionController::launched, this, [this](const QString& id, const QString&) {
        if (context_ != contextKey() || !identifier(id)) return;
        const auto result = mission_.result();
        const auto task = result.value("task").toMap();
        if (!task.isEmpty()) missions_.prepend(task);
        append("event", task.value("title").toString(), id);
        if (inlineAssign_) { assignmentPhase_ = "assigned"; assignmentTaskId_ = id; }
        pendingInstruction_.clear(); persist(); refresh(); emit changed();
    });
    contextChanged();
}
OrchestratorController::~OrchestratorController() {
    api_.cancelRequests(&chatOwner_); api_.cancelRequests(&missionsOwner_); api_.cancelRequests(&mutationOwner_);
}
bool OrchestratorController::ready() const {
    return api_.context().online && core::mayRequest(api_.context(), core::Scope::workspace, true);
}
QString OrchestratorController::contextKey() const {
    if (!api_.context().authenticated || api_.context().workspace_id.empty()) return {};
    return QString::fromStdString(core::cacheKey(api_.origin().toString().toStdString(), api_.context().user_id,
        api_.context().workspace_id, "orchestrator/conversation/v1"));
}
bool OrchestratorController::current(quint64 epoch, quint64 generation, const QString& context) const {
    return epoch == epoch_ && generation == api_.context().generation && context == contextKey();
}
void OrchestratorController::contextChanged() {
    const auto next = contextKey();
    if (next != context_ || apiGeneration_ != api_.context().generation) {
        ++epoch_; api_.cancelRequests(&chatOwner_); api_.cancelRequests(&missionsOwner_); api_.cancelRequests(&mutationOwner_);
        const auto wasBusy = busy_;
        busy_ = false; refreshing_ = false; stopping_.clear();
        if (next != context_) {
            context_ = next; messages_.clear(); conversations_.clear(); activeId_.clear(); missions_.clear();
            draft_.clear(); pendingInstruction_.clear(); language_.clear(); error_.clear();
            clearAssignment();
            ++revision_; restore();
        } else if (wasBusy) {
            error_ = "The connection changed. Your message is preserved; try again.";
        }
        apiGeneration_ = api_.context().generation;
        if (ready()) QTimer::singleShot(0, this, &OrchestratorController::refresh);
    }
    if (ready()) refreshTimer_.start(); else refreshTimer_.stop();
    emit changed();
}
void OrchestratorController::rememberActive() {
    const auto hasContent = !messages_.isEmpty() || !draft_.isEmpty() || !pendingInstruction_.isEmpty();
    if (!hasContent) return;
    if (activeId_.isEmpty()) activeId_ = QUuid::createUuid().toString(QUuid::WithoutBraces);
    QString title;
    for (const auto& value : messages_) {
        const auto item = value.toMap();
        if (item.value("role").toString() == QStringLiteral("user")) {
            title = item.value("body").toString().simplified().left(48);
            break;
        }
    }
    if (title.isEmpty()) title = draft_.simplified().left(48);
    if (title.isEmpty()) title = QStringLiteral("New chat");
    const QVariantMap entry{{"id", activeId_}, {"title", title},
        {"updated_at", QDateTime::currentDateTimeUtc().toString(Qt::ISODate)},
        {"messages", messages_}, {"draft", draft_}, {"pending_instruction", pendingInstruction_}};
    for (int i = 0; i < conversations_.size(); ++i) {
        if (conversations_.at(i).toMap().value("id").toString() == activeId_) {
            conversations_.removeAt(i);
            break;
        }
    }
    conversations_.prepend(entry);
    while (conversations_.size() > 40) conversations_.removeLast();
}
void OrchestratorController::persist() {
    ++revision_;
    if (context_.isEmpty() || context_ != contextKey()) return;
    rememberActive();
    cache_.write(context_, QJsonDocument(QJsonObject{{"messages", QJsonArray::fromVariantList(messages_)},
        {"draft", draft_}, {"language", language_}, {"pending_instruction", pendingInstruction_},
        {"active_id", activeId_}, {"conversations", QJsonArray::fromVariantList(conversations_)}}).toJson(QJsonDocument::Compact));
}
void OrchestratorController::restore() {
    if (context_.isEmpty()) return;
    const auto context = context_; const auto revision = revision_;
    cache_.read(context, this, [this, context, revision](QByteArray bytes) {
        if (context != contextKey() || revision != revision_) return;
        const auto data = QJsonDocument::fromJson(bytes).object();
        messages_ = data.value("messages").toArray().toVariantList();
        while (messages_.size() > 120) messages_.removeFirst();
        draft_ = data.value("draft").toString().left(12000);
        language_ = data.value("language").toString().left(32);
        pendingInstruction_ = data.value("pending_instruction").toString().left(12000);
        activeId_ = data.value("active_id").toString().left(80);
        conversations_.clear();
        for (const auto& value : data.value("conversations").toArray()) {
            auto item = value.toObject().toVariantMap();
            const auto id = item.value("id").toString().left(80);
            if (id.isEmpty()) continue;
            auto thread = item.value("messages").toList();
            while (thread.size() > 120) thread.removeFirst();
            item.insert("id", id);
            item.insert("title", item.value("title").toString().simplified().left(80));
            item.insert("messages", thread);
            item.insert("draft", item.value("draft").toString().left(12000));
            item.insert("pending_instruction", item.value("pending_instruction").toString().left(12000));
            conversations_.append(item);
        }
        if (conversations_.isEmpty() && (!messages_.isEmpty() || !draft_.isEmpty() || !pendingInstruction_.isEmpty()))
            rememberActive();
        resumeAutomaticAssignment();
        emit changed();
    });
}
QString OrchestratorController::earlierWorkRequest() const {
    bool skippedLatest = false;
    for (auto it = messages_.crbegin(); it != messages_.crend(); ++it) {
        const auto item = it->toMap();
        if (item.value("role").toString() != QStringLiteral("user")) continue;
        if (!skippedLatest) { skippedLatest = true; continue; }
        const auto body = item.value("body").toString().trimmed();
        if (workRequest(body)) return body.left(12000);
    }
    return {};
}
QString OrchestratorController::assignmentReply(const QString& reply) const {
    const auto kept = dropPermissionQuestions(reply);
    if (!kept.isEmpty()) return kept;
    if (language_ == QStringLiteral("fr"))
        return QStringLiteral("Je l’assigne maintenant à l’agent le plus adapté.");
    if (language_ == QStringLiteral("he"))
        return QStringLiteral("אני מעביר את זה עכשיו לסוכן המתאים.");
    return QStringLiteral("I'm assigning this now to the best-fit agent.");
}
void OrchestratorController::resumeAutomaticAssignment() {
    if (!ready() || busy_ || inlineAssign_ || messages_.isEmpty()) return;
    QString latestUser, latestAssistant;
    for (const auto& value : messages_) {
        const auto item = value.toMap();
        const auto role = item.value("role").toString();
        if (role == QStringLiteral("user")) latestUser = item.value("body").toString().trimmed();
        else if (role == QStringLiteral("assistant")) latestAssistant = item.value("body").toString();
    }
    const auto asked = asksPermission(latestAssistant);
    if (pendingInstruction_.trimmed().isEmpty() && !asked) return;
    auto brief = pendingInstruction_.trimmed();
    if (brief.isEmpty() && workRequest(latestUser)) brief = latestUser.left(12000);
    if (brief.isEmpty() && affirmative(latestUser)) brief = earlierWorkRequest();
    if (brief.isEmpty()) return;
    if (asksPermission(latestAssistant) && !messages_.isEmpty()) {
        auto last = messages_.last().toMap();
        if (last.value("role").toString() == QStringLiteral("assistant")) {
            last.insert("body", assignmentReply(latestAssistant).left(8000));
            messages_.last() = last;
        }
    }
    pendingInstruction_ = brief.left(12000);
    assignInline();
    persist();
}
void OrchestratorController::newConversation() {
    rememberActive();
    if (messages_.isEmpty() && draft_.isEmpty() && pendingInstruction_.isEmpty() && activeId_.isEmpty()) {
        emit changed(); return;
    }
    ++epoch_; api_.cancelRequests(&chatOwner_);
    busy_ = false; messages_.clear(); draft_.clear(); pendingInstruction_.clear(); error_.clear(); activeId_.clear();
    clearAssignment(); persist(); emit changed();
}
void OrchestratorController::openConversation(const QString& id) {
    if (id.isEmpty() || id == activeId_) return;
    QVariantMap selected;
    for (const auto& value : conversations_) {
        const auto item = value.toMap();
        if (item.value("id").toString() == id) { selected = item; break; }
    }
    if (selected.isEmpty()) return;
    rememberActive();
    ++epoch_; api_.cancelRequests(&chatOwner_);
    busy_ = false; error_.clear(); clearAssignment();
    activeId_ = id;
    messages_ = selected.value("messages").toList();
    while (messages_.size() > 120) messages_.removeFirst();
    draft_ = selected.value("draft").toString().left(12000);
    pendingInstruction_ = selected.value("pending_instruction").toString().left(12000);
    persist(); emit changed();
}
void OrchestratorController::setDraft(const QString& value) {
    if (draft_ == value.left(12000)) return;
    draft_ = value.left(12000); persist(); emit changed();
}
void OrchestratorController::setLanguage(const QString& value) {
    language_ = value.left(32); persist(); emit changed();
}
void OrchestratorController::append(const QString& role, const QString& text, const QString& taskId) {
    messages_.append(QVariantMap{{"id", QUuid::createUuid().toString(QUuid::WithoutBraces)},
        {"role", role}, {"body", text}, {"language", language_}, {"task_id", taskId},
        {"created_at", QDateTime::currentDateTimeUtc().toString(Qt::ISODate)}});
    while (messages_.size() > 120) messages_.removeFirst();
}
void OrchestratorController::sendMessage(const QString& text, const QString& language) {
    contextChanged(); if (busy_) return;
    const auto message = (text.isEmpty() ? draft_ : text).trimmed().left(12000);
    if (message.isEmpty()) return;
    const auto detected = messageLanguage(message);
    if (!detected.isEmpty()) language_ = detected;
    else if (!language.isEmpty()) language_ = language.left(32);
    if (assignmentPhase_ == "assigned") clearAssignment();
    draft_ = message;
    if (!ready()) { error_ = "Reconnect to speak with Moked. Your message is preserved."; persist(); emit changed(); return; }
    QJsonArray history;
    for (const auto& value : messages_) {
        const auto item = value.toMap();
        if (item.value("role") == "user" || item.value("role") == "assistant")
            history.append(QJsonObject{{"role", item.value("role").toString()}, {"body", item.value("body").toString()}});
    }
    // Retry a failed chat turn without adding a duplicate user bubble. Chat
    // itself has no side effects: only the separate dispatch can create work.
    if (!messages_.isEmpty() && messages_.last().toMap().value("role") == "user"
        && messages_.last().toMap().value("body").toString() == message) {
        if (!history.isEmpty()) history.removeLast();
    } else append("user", message);
    while (history.size() > 24) history.removeFirst();
    busy_ = true; error_.clear(); persist(); emit changed();
    const auto epoch = epoch_, generation = api_.context().generation; const auto context = context_;
    api_.request("POST", "/api/orchestrator/chat", {{"message", message}, {"language", language_}, {"conversation", history}},
        core::Scope::workspace, &chatOwner_, [this, epoch, generation, context, message](ApiResponse response) {
            if (!current(epoch, generation, context)) return;
            busy_ = false;
            const auto data = response.json.value("data").toObject(); const auto reply = data.value("reply").toString().trimmed();
            if (!response.ok() || reply.isEmpty()) {
                error_ = response.ok() ? "Moked returned an empty response. Your message is preserved; try again." : response.error;
                persist(); emit changed(); return;
            }
            const auto language = data.value("language").toString(); if (!language.isEmpty()) language_ = language.left(32);
            auto taskId = data.value("task_id").toString(); if (!knownTask(taskId)) taskId.clear();
            auto brief = data.value("mission_instruction").toString().trimmed();
            if (brief.isEmpty() && workRequest(message)) brief = message.trimmed();
            if (brief.isEmpty() && affirmative(message)) brief = earlierWorkRequest();
            const auto shown = brief.isEmpty() ? reply : (asksPermission(reply) ? assignmentReply(reply) : reply);
            append("assistant", shown.left(8000), taskId);
            brief = brief.left(12000);
            if (!brief.isEmpty() && pendingInstruction_ != brief) {
                pendingInstruction_ = brief;
                assignInline();
            }
            if (draft_ == message) draft_.clear();
            error_.clear(); persist(); emit changed(); emit assistantReplied(reply.left(8000), language_);
        });
}
void OrchestratorController::refresh() {
    if (!ready() || refreshing_) return;
    refreshing_ = true; emit changed();
    const auto epoch = epoch_, generation = api_.context().generation; const auto context = contextKey();
    api_.request("GET", "/api/orchestrator/missions", {}, core::Scope::workspace, &missionsOwner_,
        [this, epoch, generation, context](ApiResponse response) {
            if (!current(epoch, generation, context)) return;
            refreshing_ = false;
            if (response.ok() && response.json.value("data").isArray()) {
                missions_ = response.json.value("data").toArray().toVariantList();
                for (auto& value : missions_) {
                    auto task = value.toMap(); QVariantList outputs;
                    for (const auto& attachment : task.value("attachments").toList())
                        if (attachment.toMap().value("source") == "output") outputs.append(attachment);
                    task.insert("artifacts", outputs); task.insert("agent_name", task.value("assigned_agent_name")); value = task;
                }
            } else if (error_.isEmpty()) error_ = response.error;
            emit changed();
        });
}
void OrchestratorController::prepareMission() {
    if (pendingInstruction_.isEmpty() || !ready()) return;
    if (mission_.hasDraft() && mission_.instruction() != pendingInstruction_) {
        mission_.begin(); error_ = "Finish or reset the mission already being prepared, then open this proposal."; emit changed(); return;
    }
    mission_.begin(pendingInstruction_);
    if (!mission_.busy() && mission_.step() == "describe") mission_.analyze();
}
void OrchestratorController::confirmAssignment() {
    if (mission_.canLaunch()) mission_.launch();
    else prepareMission();
}
QString OrchestratorController::messageLanguage(const QString& text) const {
    static const QRegularExpression hebrew("\\p{Hebrew}", QRegularExpression::UseUnicodePropertiesOption);
    if (hebrew.match(text).hasMatch()) return QStringLiteral("he");
    static const QRegularExpression english(
        "\\b(the|can|you|your|check|website|has|have|good|what|how|this|that|with|for|and|please|does|want|need|if|seo)\\b",
        QRegularExpression::CaseInsensitiveOption);
    static const QRegularExpression french(
        "\\b(je|tu|vous|le|la|les|un|une|des|pour|avec|dans|que|qui|est|suis|merci|peux|fais|fait|bonjour|voudrais|veux)\\b|[éèêëàâçùûôîïœ]",
        QRegularExpression::CaseInsensitiveOption);
    const auto englishCount = matchCount(english, text);
    const auto frenchCount = matchCount(french, text);
    if (frenchCount > englishCount && frenchCount >= 1) return QStringLiteral("fr");
    if (englishCount > frenchCount && englishCount >= 1) return QStringLiteral("en");
    return {};
}
void OrchestratorController::clearAssignment() {
    inlineAssign_ = false; autoLaunchAttempted_ = false;
    assignmentPhase_.clear(); assignmentAgents_.clear(); assignmentAgentId_.clear(); assignmentTaskId_.clear();
}
void OrchestratorController::assignInline() {
    if (pendingInstruction_.isEmpty() || !ready()) return;
    if (mission_.hasDraft() && mission_.instruction() != pendingInstruction_) {
        if (mission_.opened() || mission_.busy()) return;
        mission_.reset();
    }
    inlineAssign_ = true; autoLaunchAttempted_ = false; assignmentTaskId_.clear();
    assignmentPhase_ = QStringLiteral("matching");
    emit changed();
    mission_.beginInline(pendingInstruction_);
    if (!mission_.busy() && mission_.step() == "describe") mission_.analyze();
}
void OrchestratorController::scheduleLaunch() {
    autoLaunchAttempted_ = true;
    const auto epoch = epoch_; const auto generation = api_.context().generation; const auto context = contextKey();
    QTimer::singleShot(1200, this, [this, epoch, generation, context] {
        if (!current(epoch, generation, context) || !inlineAssign_) return;
        if (mission_.step() == "recommend" && mission_.canLaunch() && !mission_.customSelected() && mission_.grants().isEmpty())
            mission_.launch();
    });
}
void OrchestratorController::syncAssignment() {
    if (!inlineAssign_ || context_ != contextKey()) return;
    const auto step = mission_.step();
    auto roster = ((step == "recommend" || step == "launching" || step == "done") && !mission_.candidates().isEmpty())
        ? mission_.candidates() : mission_.roster();
    while (roster.size() > 6) roster.removeLast();
    assignmentAgents_ = roster;
    assignmentAgentId_ = mission_.selectedAgentId();
    if (step == "done") assignmentPhase_ = QStringLiteral("assigned");
    else if (step == "launching") assignmentPhase_ = QStringLiteral("launching");
    else if (step == "analyzing" || mission_.busy()) assignmentPhase_ = QStringLiteral("matching");
    else if (step == "recommend") {
        const auto grants = !mission_.grants().isEmpty();
        const auto unmatched = mission_.customSelected() || !mission_.capabilityWarning().isEmpty();
        if (mission_.canLaunch() && !grants && !unmatched) {
            assignmentPhase_ = QStringLiteral("chosen");
            if (!autoLaunchAttempted_) scheduleLaunch();
        } else if (unmatched && !grants) assignmentPhase_ = QStringLiteral("unmatched");
        else assignmentPhase_ = QStringLiteral("review");
    } else if (step == "describe" && !mission_.error().isEmpty()) clearAssignment();
    emit changed();
}
bool OrchestratorController::knownTask(const QString& id) const {
    if (!identifier(id)) return false;
    return std::any_of(missions_.cbegin(), missions_.cend(), [&id](const QVariant& task) { return task.toMap().value("id").toString() == id; });
}
void OrchestratorController::reviewMission(const QString& id) { if (knownTask(id)) emit openTask(id); }
void OrchestratorController::cancelMission(const QString& id) {
    if (!ready() || !knownTask(id) || stopping_.contains(id)) return;
    stopping_.insert(id); const auto epoch = epoch_, generation = api_.context().generation; const auto context = contextKey();
    api_.request("POST", "/api/orchestrator/missions/" + id + "/stop", {}, core::Scope::workspace, &mutationOwner_,
        [this, epoch, generation, context, id](ApiResponse response) {
            if (!current(epoch, generation, context)) return;
            stopping_.remove(id);
            if (!response.ok()) error_ = response.error;
            else { error_.clear(); refresh(); }
            emit changed();
        });
}
void OrchestratorController::clearConversation() {
    ++epoch_; api_.cancelRequests(&chatOwner_); api_.cancelRequests(&missionsOwner_); api_.cancelRequests(&mutationOwner_);
    busy_ = false; refreshing_ = false; stopping_.clear(); messages_.clear(); conversations_.clear(); activeId_.clear();
    draft_.clear(); pendingInstruction_.clear(); error_.clear();
    clearAssignment(); persist(); emit changed();
}
}
