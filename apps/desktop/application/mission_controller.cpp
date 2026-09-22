#include <mokaid/application/mission_controller.hpp>
#include <QFileInfo>
#include <QMimeDatabase>
#include <QRegularExpression>
#include <QUuid>
#include <algorithm>

namespace mokaid::desktop {
namespace {
bool identifier(const QString& text) {
    static const QRegularExpression pattern("^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$");
    return pattern.match(text).hasMatch();
}
QString newId() { return QUuid::createUuid().toString(QUuid::WithoutBraces); }
}
MissionController::MissionController(ApiClient& api, SessionController& session, PhoenixClient& realtime,
                                     ActivityController& activity, QObject* parent)
    : QObject(parent), api_(api), session_(session), activity_(activity),
      context_(contextKey()), activatedAt_(QDateTime::currentDateTimeUtc()), apiGeneration_(api.context().generation) {
    connect(&session_, &SessionController::changed, this, &MissionController::contextChanged);
    connect(&session_, &SessionController::workspaceChanged, this, &MissionController::contextChanged);
    connect(&session_, &SessionController::cleared, this, [this] { reset(); contextChanged(); });
    connect(&api_, &ApiClient::onlineChanged, this, [this] { contextChanged(); emit changed(); });
    connect(&activity_, &ActivityController::changed, this, &MissionController::consumeNotifications);
    connect(&realtime, &PhoenixClient::eventReceived, this,
        [this](const QString& topic, const QString& event, const QJsonObject& payload) {
            if (context_ != contextKey() || !api_.context().authenticated ||
                topic != "notifications:" + QString::fromStdString(api_.context().user_id) || event != "notification.created") return;
            const auto id = payload.value("notification_id").toString();
            if (identifier(id) && !seenNotifications_.contains(id) && pendingNotifications_.size() < 256)
                pendingNotifications_.insert(id);
            // The broadcast has no workspace identity. ActivityController reloads
            // the scoped endpoint; never display the broadcast title or body.
        });
}
MissionController::~MissionController() {
    api_.cancelRequests(&draftOwner_); api_.cancelRequests(&agentsOwner_);
}
QString MissionController::contextKey() const {
    if (!api_.context().authenticated) return {};
    return QString::fromStdString(core::cacheKey(api_.origin().toString().toStdString(), api_.context().user_id,
                                               api_.context().workspace_id, "mission"));
}
bool MissionController::ready() const {
    return api_.context().online && core::mayRequest(api_.context(), core::Scope::workspace, true);
}
bool MissionController::current(quint64 epoch, quint64 generation, const QString& context) const {
    return epoch == epoch_ && generation == api_.context().generation && context == contextKey();
}
void MissionController::contextChanged() {
    const auto next = contextKey();
    if (context_ != next) {
        reset(); context_ = next; seenNotifications_.clear(); notificationOrder_.clear(); pendingNotifications_.clear();
        activatedAt_ = QDateTime::currentDateTimeUtc();
    } else if (apiGeneration_ != api_.context().generation) {
        // Credential rotation may cancel a pending request in the same workspace.
        // Preserve its draft and successful uploads, and release the busy state.
        ++epoch_; api_.cancelRequests(&draftOwner_); api_.cancelRequests(&agentsOwner_);
        if (step_ == "launching") {
            step_ = "recommend"; launchUncertain_ = true;
            error_ = "The connection changed while starting. Retry to safely recover the same mission.";
        } else if (busy()) { step_ = "describe"; error_ = "The connection changed. Your mission draft is preserved; try again."; }
        uploading_ = false;
        for (auto& file : attachments_) if (file.status == "uploading") file.status = "queued";
    }
    apiGeneration_ = api_.context().generation;
    emit changed();
}
bool MissionController::hasDraft() const {
    return step_ != "done" && (!instruction_.trimmed().isEmpty() || !attachments_.isEmpty() || busy());
}
bool MissionController::canLaunch() const {
    if (!ready() || busy() || step_ != "recommend" || analysis_.value("task").toObject().value("title").toString().trimmed().isEmpty()) return false;
    if (std::any_of(attachments_.cbegin(), attachments_.cend(), [](const auto& file) { return file.status != "ready"; })) return false;
    return customSelected_ ? !customAgent_.value("display_name").toString().trimmed().isEmpty() : identifier(selectedAgentId_);
}
QVariantList MissionController::attachments() const {
    QVariantList result;
    for (const auto& file : attachments_) result.append(QVariantMap{{"id", file.id}, {"name", file.name},
        {"size_bytes", file.size}, {"mime_type", file.mimeType}, {"status", file.status}, {"error", file.error},
        {"drive_item_id", file.uploaded.value("id").toString()}});
    return result;
}
QVariantList MissionController::grants() const {
    QVariantList result;
    for (const auto& value : analysis_.value("mcp_suggestions").toArray()) {
        const auto item = value.toObject(); const auto id = item.value("installation_id").toString();
        if (item.value("status").toString() == "needs_grant" && identifier(id))
            result.append(QVariantMap{{"id", id}, {"name", item.value("server_name").toString()}, {"selected", grants_.contains(id)}});
    }
    return result;
}
void MissionController::fail(const QString& message) { error_ = message; emit changed(); }
void MissionController::begin(const QString& instruction) { openDraft(instruction, true); }
void MissionController::beginInline(const QString& instruction) { openDraft(instruction, false); }
void MissionController::openDraft(const QString& instruction, bool openSheet) {
    contextChanged();
    if (step_ == "done") reset();
    opened_ = openSheet;
    if (!instruction.isEmpty() && instruction_.isEmpty() && !busy()) setInstruction(instruction);
    loadAgents(); emit changed();
}
void MissionController::beginForAgent(const QString& agentId, const QString& instruction) {
    begin(instruction);
    if (!busy() && identifier(agentId)) {
        preferredAgentId_ = agentId;
        if (step_ == "recommend") selectAgent(agentId);
    }
}
void MissionController::close() { opened_ = false; emit changed(); }
void MissionController::reset() {
    ++epoch_; api_.cancelRequests(&draftOwner_); api_.cancelRequests(&agentsOwner_);
    attachments_.clear(); agents_.clear(); candidates_.clear(); analysis_ = {}; customAgent_ = {}; result_ = {};
    instruction_.clear(); selectedAgentId_.clear(); preferredAgentId_.clear(); grants_.clear(); error_.clear(); requestId_.clear();
    opened_ = false; uploading_ = false; customSelected_ = false; launchUncertain_ = false; step_ = "describe"; emit changed();
}
void MissionController::invalidateAnalysis() {
    analysis_ = {}; customAgent_ = {}; candidates_.clear(); grants_.clear(); selectedAgentId_.clear();
    customSelected_ = false; requestId_.clear(); result_ = {}; step_ = "describe";
}
void MissionController::setInstruction(const QString& text) {
    if (busy() || launchUncertain_ || instruction_ == text.left(50000)) return;
    instruction_ = text.left(50000); invalidateAnalysis(); error_.clear(); emit changed();
}
MissionController::Attachment* MissionController::attachment(const QString& id) {
    const auto found = std::find_if(attachments_.begin(), attachments_.end(), [&id](const auto& file) { return file.id == id; });
    return found == attachments_.end() ? nullptr : &*found;
}
void MissionController::addFiles(const QVariantList& urls) {
    contextChanged();
    if (busy() || launchUncertain_) { fail("Finish the current step before adding files. Retry an uncertain launch to recover the same mission."); return; }
    if (step_ == "done") reset();
    opened_ = true; error_.clear();
    bool added = false;
    for (const auto& value : urls) {
        const auto url = value.toUrl();
        if (!url.isLocalFile()) { error_ = "Choose files stored on this computer."; continue; }
        const QFileInfo info(url.toLocalFile());
        if (!info.isFile() || !info.isReadable()) { error_ = "This item cannot be read. For a folder, attach a ZIP archive."; continue; }
        if (info.size() > maximumFileBytes()) { error_ = "Each attachment can be up to 49 MB. Split or compress larger files."; continue; }
        const auto path = info.canonicalFilePath();
        if (std::any_of(attachments_.cbegin(), attachments_.cend(), [&path](const auto& file) { return file.canonicalPath == path; })) continue;
        if (attachments_.size() >= 20) { error_ = "A mission can include up to 20 attachments."; break; }
        Attachment file; file.id = newId(); file.canonicalPath = path; file.name = info.fileName(); file.size = info.size();
        file.mimeType = QMimeDatabase().mimeTypeForFile(info, QMimeDatabase::MatchExtension).name();
        attachments_.append(std::move(file)); added = true;
    }
    if (added) invalidateAnalysis();
    emit changed();
}
void MissionController::removeFile(const QString& id) {
    if (busy() || launchUncertain_) return;
    const auto removed = attachments_.removeIf([&id](const auto& file) { return file.id == id; });
    if (removed) { invalidateAnalysis(); error_.clear(); emit changed(); }
}
void MissionController::retryFile(const QString& id) {
    contextChanged();
    auto* file = attachment(id);
    if (busy() || !file || file->status != "error") return;
    if (!ready()) { fail("Reconnect to upload this file. Your draft is preserved."); return; }
    error_.clear(); uploadOne(id, false);
}
void MissionController::loadAgents() {
    if (!ready()) return;
    api_.cancelRequests(&agentsOwner_);
    const auto epoch = epoch_, generation = api_.context().generation; const auto context = contextKey();
    api_.request("GET", "/api/agents", {}, core::Scope::workspace, &agentsOwner_, [this, epoch, generation, context](ApiResponse response) {
        if (!current(epoch, generation, context) || !response.ok()) return;
        agents_.clear();
        for (const auto& value : response.json.value("data").toArray()) {
            const auto agent = value.toObject();
            if (identifier(agent.value("id").toString()) && agent.value("kind").toString() != "human_linked" &&
                agent.value("status").toString() != "archived" && agent.value("status").toString() != "disabled")
                agents_.append(agent.toVariantMap());
        }
        rebuildCandidates(); emit changed();
    });
}
void MissionController::rebuildCandidates() {
    candidates_.clear();
    if (analysis_.isEmpty()) return;
    const auto recommendation = analysis_.value("recommendation").toObject();
    const auto recommended = recommendation.value("agent_id").toString();
    QSet<QString> seen;
    auto append = [&](QString id, int confidence, const QString& reason, bool primary) {
        if (!identifier(id) || seen.contains(id)) return;
        QVariantMap card{{"id", id}, {"display_name", "Agent"}, {"role_title", ""}};
        for (const auto& value : agents_) if (value.toMap().value("id").toString() == id) { card = value.toMap(); break; }
        card.insert("confidence", std::clamp(confidence, 0, 100)); card.insert("reason", reason); card.insert("recommended", primary);
        candidates_.append(card); seen.insert(id);
    };
    append(recommended, recommendation.value("confidence").toInt(), recommendation.value("reason").toString(), true);
    for (const auto& alternative : recommendation.value("alternatives").toArray()) {
        const auto item = alternative.toObject();
        append(item.value("agent_id").toString(), item.value("confidence").toInt(), item.value("reason").toString(), false);
    }
    if (!preferredAgentId_.isEmpty()) append(preferredAgentId_, 0, "You selected this agent", false);
    for (const auto& agent : agents_) append(agent.toMap().value("id").toString(), 0, "Choose this agent yourself", false);
}
void MissionController::analyze() {
    contextChanged();
    if (busy() || launchUncertain_) return;
    if (instruction_.trimmed().isEmpty() && attachments_.isEmpty()) { fail("Describe the mission or attach a file to get started."); return; }
    if (!ready()) { fail("Reconnect to prepare this mission. Your draft is preserved."); return; }
    error_.clear(); step_ = "analyzing"; emit changed(); uploadNext();
}
void MissionController::uploadNext() {
    for (const auto& file : attachments_) if (file.status != "ready") { uploadOne(file.id, true); return; }
    requestAnalysis();
}
void MissionController::uploadOne(const QString& id, bool continueAnalysis) {
    auto* file = attachment(id); if (!file) return;
    const QFileInfo info(file->canonicalPath);
    if (!info.isFile() || !info.isReadable() || info.size() > maximumFileBytes()) {
        file->status = "error"; file->error = "This file is unavailable or exceeds the 49 MB limit.";
        step_ = "describe"; fail(file->error); return;
    }
    file->status = "uploading"; file->error.clear(); file->size = info.size(); uploading_ = true;
    const auto epoch = epoch_, generation = api_.context().generation; const auto context = contextKey();
    emit changed();
    api_.upload("/api/drive/upload", {QUrl::fromLocalFile(file->canonicalPath)}, {}, core::Scope::workspace, &draftOwner_,
        [this, id, epoch, generation, context, continueAnalysis](ApiResponse response) {
            if (!current(epoch, generation, context)) return;
            uploading_ = false; auto* file = attachment(id); if (!file) return;
            const auto uploaded = response.json.value("data").toObject();
            if (!response.ok() || !identifier(uploaded.value("id").toString())) {
                file->status = "error"; file->error = response.ok() ? "The upload response is invalid. Try this file again." : response.error;
                step_ = "describe"; fail(file->error); return;
            }
            file->status = "ready"; file->uploaded = uploaded; file->error.clear();
            emit changed(); if (continueAnalysis) uploadNext();
        });
}
void MissionController::requestAnalysis() {
    QJsonArray files;
    for (const auto& file : attachments_) files.append(QJsonObject{{"drive_item_id", file.uploaded.value("id")},
        {"name", file.uploaded.value("name").toString(file.name)}, {"mime_type", file.mimeType}, {"size_bytes", file.size}});
    const auto epoch = epoch_, generation = api_.context().generation; const auto context = contextKey();
    api_.request("POST", "/api/dispatch/analyze", {{"instruction", instruction_}, {"files", files}}, core::Scope::workspace, &draftOwner_,
        [this, epoch, generation, context](ApiResponse response) {
            if (!current(epoch, generation, context)) return;
            step_ = "describe";
            const auto data = response.json.value("data").toObject(); const auto recommendation = data.value("recommendation").toObject();
            if (!response.ok()) { fail(response.error); return; }
            if (data.value("task").toObject().value("title").toString().trimmed().isEmpty() || recommendation.isEmpty()) {
                fail("The mission recommendation is incomplete. Please try again."); return;
            }
            analysis_ = data; customAgent_ = recommendation.value("custom_agent").toObject(); grants_.clear();
            rebuildCandidates(); selectedAgentId_ = recommendation.value("agent_id").toString();
            customSelected_ = recommendation.value("mode").toString() == "custom_agent" && !customAgent_.isEmpty();
            if (!preferredAgentId_.isEmpty()) {
                for (const auto& candidate : candidates_) if (candidate.toMap().value("id").toString() == preferredAgentId_) {
                    selectedAgentId_ = preferredAgentId_; customSelected_ = false; break;
                }
            }
            if (customSelected_) selectedAgentId_.clear();
            requestId_ = newId(); step_ = "recommend"; error_.clear(); emit changed();
        });
}
void MissionController::edit() {
    if (busy() || launchUncertain_) return;
    step_ = "describe"; error_.clear(); emit changed();
}
void MissionController::selectAgent(const QString& id) {
    if (busy() || launchUncertain_) return;
    for (const auto& candidate : candidates_) if (candidate.toMap().value("id").toString() == id) {
        selectedAgentId_ = id; customSelected_ = false; requestId_ = newId(); emit changed(); return;
    }
}
void MissionController::selectCustomAgent() {
    if (busy() || launchUncertain_ || customAgent_.isEmpty()) return;
    customSelected_ = true; selectedAgentId_.clear(); requestId_ = newId(); emit changed();
}
void MissionController::configureCustomAgent(const QString& name, const QString& role, const QString& instructions) {
    if (busy() || launchUncertain_ || customAgent_.isEmpty()) return;
    customAgent_.insert("display_name", name.left(100)); customAgent_.insert("role_title", role.left(200));
    if (!instructions.isNull()) customAgent_.insert("instructions", instructions.left(20000));
    requestId_ = newId(); emit changed();
}
void MissionController::setGrant(const QString& id, bool allowed) {
    if (busy() || launchUncertain_) return;
    for (const auto& value : analysis_.value("mcp_suggestions").toArray()) {
        const auto suggestion = value.toObject();
        if (suggestion.value("installation_id").toString() == id && suggestion.value("status").toString() == "needs_grant") {
            if (allowed) grants_.insert(id); else grants_.remove(id);
            requestId_ = newId(); emit changed(); return;
        }
    }
}
QString MissionController::capabilityWarning() const {
    if (customSelected_ || selectedAgentId_.isEmpty()) return {};
    const auto recommendation = analysis_.value("recommendation").toObject();
    for (const auto& value : candidates_) if (value.toMap().value("id").toString() == selectedAgentId_) {
        if (value.toMap().value("confidence").toInt() >= 45 && recommendation.value("mode").toString() == "existing_agent") return {};
        return "This agent is not a strong match for this mission. A specialist may produce a better result.";
    }
    return {};
}
void MissionController::launch() {
    contextChanged(); if (!canLaunch()) return;
    QJsonArray ids, grants;
    for (const auto& file : attachments_) ids.append(file.uploaded.value("id"));
    for (const auto& id : grants_) grants.append(id);
    int confidence = customSelected_ ? 100 : 0;
    for (const auto& value : candidates_) if (value.toMap().value("id").toString() == selectedAgentId_) confidence = value.toMap().value("confidence").toInt();
    const auto recommendation = analysis_.value("recommendation").toObject();
    QJsonObject body{{"instruction", instruction_}, {"task", analysis_.value("task")}, {"drive_item_ids", ids},
        {"grant_installation_ids", grants}, {"start_now", true}, {"client_request_id", requestId_},
        {"capability_match", QJsonObject{{"mode", recommendation.value("mode")}, {"confidence", confidence},
            {"reason", recommendation.value("reason")}, {"warning_shown", !capabilityWarning().isEmpty()}}}};
    if (customSelected_) body.insert("custom_agent", customAgent_); else body.insert("agent_id", selectedAgentId_);
    step_ = "launching"; error_.clear(); emit changed();
    const auto epoch = epoch_, generation = api_.context().generation; const auto context = contextKey();
    api_.request("POST", "/api/dispatch/confirm", body, core::Scope::workspace, &draftOwner_,
        [this, epoch, generation, context](ApiResponse response) {
            if (!current(epoch, generation, context)) return;
            step_ = "recommend";
            if (!response.ok()) {
                launchUncertain_ = response.networkError || response.status == 0 || response.status >= 500;
                fail(launchUncertain_ ? response.error + " Retry to safely recover the same mission." : response.error); return;
            }
            const auto data = response.json.value("data").toObject(); const auto taskId = data.value("task").toObject().value("id").toString();
            if (!identifier(taskId) || !identifier(data.value("run_id").toString()) ||
                !identifier(data.value("agent").toObject().value("id").toString())) {
                launchUncertain_ = true; fail("The launch response is incomplete. Retry to safely recover the same mission."); return;
            }
            launchUncertain_ = false; result_ = data; result_.insert("agent_created", customSelected_); step_ = "done"; emit changed();
            emit launched(taskId, data.value("agent").toObject().value("id").toString());
        });
}
void MissionController::viewTask() {
    const auto id = result_.value("task").toObject().value("id").toString();
    if (identifier(id)) { close(); emit openTask(id); }
}
void MissionController::consumeNotifications() {
    if (context_ != contextKey() || apiGeneration_ != api_.context().generation || context_.isEmpty() || !api_.context().online) return;
    for (const auto& value : activity_.notifications()) {
        auto notification = value.toMap(); const auto id = notification.value("id").toString();
        if (!identifier(id) || seenNotifications_.contains(id)) continue;
        const auto workspace = notification.value("workspace_id").toString();
        if (!workspace.isEmpty() && workspace != QString::fromStdString(api_.context().workspace_id)) continue;
        const auto created = QDateTime::fromString(notification.value("inserted_at").toString(), Qt::ISODateWithMs);
        const bool fresh = pendingNotifications_.remove(id) || (created.isValid() && created >= activatedAt_);
        seenNotifications_.insert(id); notificationOrder_.append(id);
        while (notificationOrder_.size() > 512) seenNotifications_.remove(notificationOrder_.takeFirst());
        const auto kind = notification.value("kind").toString();
        if (fresh && notification.value("read_at").toString().isEmpty() && notification.value("resource_type").toString() == "task" &&
            identifier(notification.value("resource_id").toString()) &&
            (kind == "ai_run_completed" || kind == "ai_run_failed" || kind == "approval_requested" || kind == "ai_run_needs_input"))
            emit completed(notification);
    }
}
}
