#include <mokaid/application/orchestrator_controller.hpp>
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
    connect(&mission_, &MissionController::launched, this, [this](const QString& id, const QString&) {
        if (context_ != contextKey() || !identifier(id)) return;
        const auto result = mission_.result();
        const auto task = result.value("task").toMap();
        if (!task.isEmpty()) missions_.prepend(task);
        append("event", task.value("title").toString(), id);
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
            context_ = next; messages_.clear(); missions_.clear(); draft_.clear(); pendingInstruction_.clear(); language_.clear(); error_.clear();
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
void OrchestratorController::persist() {
    ++revision_;
    if (context_.isEmpty() || context_ != contextKey()) return;
    cache_.write(context_, QJsonDocument(QJsonObject{{"messages", QJsonArray::fromVariantList(messages_)},
        {"draft", draft_}, {"language", language_}, {"pending_instruction", pendingInstruction_}}).toJson(QJsonDocument::Compact));
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
        pendingInstruction_ = data.value("pending_instruction").toString().left(12000); emit changed();
    });
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
    if (!language.isEmpty()) language_ = language.left(32);
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
            append("assistant", reply.left(8000), taskId);
            pendingInstruction_ = data.value("mission_instruction").toString().left(12000);
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
    busy_ = false; refreshing_ = false; stopping_.clear(); messages_.clear(); draft_.clear(); pendingInstruction_.clear(); error_.clear(); persist(); emit changed();
}
}
