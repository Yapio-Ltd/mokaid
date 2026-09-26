#include <mokaid/application/office_controller.hpp>
#include <QJsonDocument>
#include <QRegularExpression>
#include <algorithm>

namespace mokaid::desktop {
namespace {
constexpr qsizetype maxStreamCharacters = 1000000;
constexpr qsizetype maxStreams = 8;
constexpr qsizetype maxRetiredStreams = 256;
constexpr qsizetype maxRealtimeMessages = 512;
bool terminalActivity(const QVariantMap& event) {
    const auto status = event.value("status").toString();
    return status == "ok" || status == "error" || status == "denied" || status == "rejected";
}
bool preferLiveActivity(const QVariantMap& canonical, const QVariantMap& live) {
    if (!terminalActivity(canonical)) return true;
    if (!terminalActivity(live)) return false;
    const auto canonicalEnd = canonical.value("finished_at").toString();
    const auto liveEnd = live.value("finished_at").toString();
    return !liveEnd.isEmpty() && !canonicalEnd.isEmpty() && liveEnd > canonicalEnd;
}
}
OfficeController::OfficeController(ApiClient& api, SessionController& session, PhoenixClient& realtime,
                                   CacheStore& cache, QObject* parent)
    : QObject(parent), api_(api), session_(session), realtime_(realtime), cache_(cache),
      context_(contextKey()), apiGeneration_(api.context().generation) {
    workRefresh_.setSingleShot(true); workRefresh_.setInterval(250);
    workPoll_.setInterval(20000);
    connect(&workRefresh_, &QTimer::timeout, this, &OfficeController::refreshWork);
    connect(&workPoll_, &QTimer::timeout, this, &OfficeController::refreshWork);
    publishStream_.setSingleShot(true); publishStream_.setInterval(33);
    debounceRefresh_.setSingleShot(true); debounceRefresh_.setInterval(200);
    connect(&publishStream_, &QTimer::timeout, this, &OfficeController::publishStreams);
    connect(&debounceRefresh_, &QTimer::timeout, this, &OfficeController::refresh);
    connect(&session_, &SessionController::changed, this, &OfficeController::contextChanged);
    connect(&session_, &SessionController::established, this, [this] { contextChanged(); refresh(); });
    connect(&session_, &SessionController::workspaceChanged, this, &OfficeController::contextChanged);
    connect(&session_, &SessionController::cleared, this, &OfficeController::reset);
    connect(&api_, &ApiClient::onlineChanged, this, [this] {
        contextChanged();
        if (api_.context().online) { refresh(); refreshMessages(); }
        else markWorkConnection("offline");
    });
    connect(&realtime_, &PhoenixClient::connectionChanged, this, [this](bool connected) {
        workConnected_ = connected;
        if (!connected) { clearStreams(); markWorkConnection("reconnecting"); }
        else refreshWork();
    });
    connect(&realtime_, &PhoenixClient::rejoined, this, [this] {
        clearStreams(); realtimeMessages_.clear(); refresh(); refreshMessages();
    });
    connect(&realtime_, &PhoenixClient::eventReceived, this, &OfficeController::receive);
}
OfficeController::~OfficeController() {
    api_.cancelRequests(&agentsOwner_); api_.cancelRequests(&historyOwner_); api_.cancelRequests(&mutationOwner_); api_.cancelRequests(&workOwner_);
}
QString OfficeController::workspaceId() const {
    return api_.context().authenticated ? QString::fromStdString(api_.context().workspace_id)
        : (session_.authenticated() ? session_.workspaceId() : QString{});
}
QString OfficeController::contextKey() const {
    const auto user = api_.context().authenticated ? QString::fromStdString(api_.context().user_id)
        : (session_.authenticated() ? session_.user().value("id").toString() : QString{});
    if (user.isEmpty() || workspaceId().isEmpty()) return {};
    return QString::fromStdString(core::cacheKey(api_.origin().toString().toStdString(), user.toStdString(),
                                               workspaceId().toStdString(), "office"));
}
QString OfficeController::cacheKey(const QString& path) const {
    const auto user = api_.context().authenticated ? QString::fromStdString(api_.context().user_id)
        : session_.user().value("id").toString();
    return QString::fromStdString(core::cacheKey(api_.origin().toString().toStdString(), user.toStdString(),
                                               workspaceId().toStdString(), path.toStdString()));
}
void OfficeController::contextChanged() {
    if (context_ == contextKey() && apiGeneration_ == api_.context().generation) return;
    reset(); refresh();
}
void OfficeController::get(const QString& path, QObject* owner, std::function<bool()> applicable,
                           std::function<void(QJsonObject)> done) {
    if (contextKey().isEmpty()) { loading_ = false; emit changed(); return; }
    const auto key = cacheKey(path);
    const auto generation = generation_;
    const auto context = contextKey();
    const auto apiGeneration = api_.context().generation;
    auto current = [this, generation, context, apiGeneration, applicable] {
        return generation == generation_ && context == contextKey() &&
               apiGeneration == api_.context().generation && applicable();
    };
    auto fallback = [this, owner, key, current, done] {
        cache_.read(key, owner, [this, current, done](QByteArray bytes) {
            if (!current()) return;
            if (bytes.isEmpty()) {
                loading_ = false; error_ = "No saved data is available for this view while offline.";
                emit changed(); return;
            }
            done(QJsonDocument::fromJson(bytes).object());
        });
    };
    if (!api_.context().online) { fallback(); return; }
    api_.request("GET", path, {}, core::Scope::workspace, owner,
        [this, current, key, fallback, done = std::move(done)](ApiResponse response) {
            if (!current()) return;
            if (!response.ok()) {
                error_ = response.error; loading_ = false; emit changed();
                if (response.networkError) fallback();
                return;
            }
            cache_.write(key, response.bytes); error_.clear(); done(std::move(response.json));
        });
}
void OfficeController::refresh() {
    contextChanged(); api_.cancelRequests(&agentsOwner_);
    const auto request = ++agentsRequest_;
    get("/api/agents", &agentsOwner_, [this, request] { return request == agentsRequest_; }, [this](QJsonObject json) {
        auto agents = json.value("data").toArray().toVariantList();
        for (auto& value : agents) {
            auto record = value.toMap(); record["name"] = record.value("display_name");
            const auto match = QRegularExpression("avatar_(male|female|corporate|developer|design|finance|research|legal|byte|nyx|moss)(?:[._/]|$)")
                .match(record.value("avatar_cdn_path").toString());
            record["asset_type"] = !record.value("avatar_native_cdn_path").toString().isEmpty()
                ? "custom:" + record.value("avatar_asset_id").toString()
                : match.hasMatch() ? match.captured(1) : "male";
            if (record.value("id") == selected_.value("id")) selected_ = record;
            value = record;
        }
        agents_ = std::move(agents);
        if (!selected_.isEmpty() && std::none_of(agents_.cbegin(), agents_.cend(), [this](const QVariant& item) {
                return item.toMap().value("id") == selected_.value("id");
            })) closeChat();
        emit agentsChanged(); emit changed();
        refreshWork();
    });
}
QVariantList OfficeController::agents() const {
    auto result = agents_;
    for (auto& value : result) {
        auto agent = value.toMap();
        const auto taskId = agent.value("current_task_id").toString();
        auto task = work_.value(taskId);
        const auto connection = task.value("screen_connection", "syncing");
        // A reassigned task must never remain on its previous owner's desk.
        if (task.value("assigned_agent_id").toString() != agent.value("id").toString()) task.clear();
        agent["screen_task"] = task;
        agent["screen_connection"] = !api_.context().online ? "offline"
            : connection.toString();
        value = agent;
    }
    return result;
}
void OfficeController::markWorkConnection(const QString& state) {
    for (auto it = work_.begin(); it != work_.end(); ++it) it.value()["screen_connection"] = state;
    emit agentsChanged();
}
void OfficeController::refreshWork() {
    if (contextKey().isEmpty()) return;
    QSet<QString> wanted;
    for (const auto& value : agents_) {
        const auto agent = value.toMap();
        const auto task = agent.value("current_task_id").toString();
        const int seat = agent.value("seat_index", -1).toInt();
        if (seat >= 0 && seat < 9 && agent.value("status") != "archived" && !task.isEmpty()) wanted.insert(task);
    }
    for (auto it = work_.begin(); it != work_.end();) {
        if (!wanted.contains(it.key())) it = work_.erase(it); else ++it;
    }
    if (wanted.isEmpty()) { workPoll_.stop(); liveWorkEvents_.clear(); return; }
    if (!workPoll_.isActive()) workPoll_.start();
    if (!api_.context().online) { markWorkConnection("offline"); return; }
    const auto generation = generation_;
    const auto apiGeneration = api_.context().generation;
    for (const auto& id : wanted) {
        const auto request = ++workRequests_[id];
        api_.request("GET", "/api/tasks/" + QString::fromLatin1(QUrl::toPercentEncoding(id)), {},
            core::Scope::workspace, &workOwner_, [this, id, request, generation, apiGeneration](ApiResponse response) {
            if (generation != generation_ || apiGeneration != api_.context().generation || workRequests_.value(id) != request) return;
            const bool stillAssigned = std::any_of(agents_.cbegin(), agents_.cend(), [&id](const QVariant& value) {
                return value.toMap().value("current_task_id").toString() == id;
            });
            if (!stillAssigned) return;
            auto task = response.json.value("data").toObject().toVariantMap();
            if (!response.ok() || task.value("id").toString() != id) {
                work_[id] = {{"screen_connection", "unavailable"}};
                emit agentsChanged(); return;
            }
            auto run = task.value("latest_run").toMap();
            auto events = run.value("tool_activity").toList();
            const auto runId = run.value("id").toString();
            QVariantList retainedLive;
            for (const auto& live : liveWorkEvents_.value(runId)) {
                const auto eventId = live.toMap().value("id").toString();
                const auto found = std::find_if(events.begin(), events.end(), [&eventId](const QVariant& item) {
                    return item.toMap().value("id").toString() == eventId;
                });
                if (found == events.end()) { events.append(live); retainedLive.append(live); }
                else if (preferLiveActivity(found->toMap(), live.toMap())) { *found = live; retainedLive.append(live); }
                // Canonical terminal activity heals missed completion events on reconnect.
            }
            if (retainedLive.isEmpty()) liveWorkEvents_.remove(runId); else liveWorkEvents_[runId] = retainedLive;
            while (events.size() > 32) events.removeFirst();
            run["tool_activity"] = events; task["latest_run"] = run;
            task["screen_connection"] = workConnected_ ? "live" : "synced";
            work_[id] = task;
            emit agentsChanged();
        });
    }
}
void OfficeController::invalidateChat() {
    ++chatGeneration_; ++historyRequest_;
    api_.cancelRequests(&historyOwner_); api_.cancelRequests(&mutationOwner_);
    sending_ = false; loading_ = false; realtimeMessages_.clear(); messages_.clear(); clearStreams();
}
void OfficeController::selectAgent(const QString& id) {
    contextChanged();
    const auto found = std::find_if(agents_.cbegin(), agents_.cend(), [&id](const QVariant& item) {
        return item.toMap().value("id").toString() == id;
    });
    if (found == agents_.cend()) return;
    if (!selected_.isEmpty()) drafts_[selected_.value("id").toString()] = draft_;
    const auto selected = found->toMap();
    invalidateChat(); selected_ = selected; draft_ = drafts_.value(id);
    conversations_.clear(); conversation_.clear(); activeConversation_.clear(); conversationKnown_ = false;
    loading_ = true; error_.clear(); emit changed(); emit messagesChanged(); refreshMessages();
    if (api_.context().online) api_.request("POST", "/api/agents/" + id + "/chat/read", {},
        core::Scope::workspace, &mutationOwner_, [](ApiResponse) {});
}
QString OfficeController::viewedConversation() const {
    return conversation_.isEmpty() ? activeConversation_ : conversation_;
}
void OfficeController::refreshMessages() {
    contextChanged();
    const auto id = selected_.value("id").toString();
    if (id.isEmpty()) return;
    api_.cancelRequests(&historyOwner_);
    const auto request = ++historyRequest_;
    // Resolve the active ID first: default /chat cannot identify an empty conversation.
    get("/api/agents/" + id + "/conversations", &historyOwner_, [this, request] { return request == historyRequest_; },
        [this, request](QJsonObject json) {
            conversations_ = json.value("data").toArray().toVariantList();
            QString active;
            for (const auto& value : conversations_) {
                const auto record = value.toMap();
                if (record.value("status").toString() == "active" && record.value("agent_id") == selected_.value("id")) {
                    active = record.value("id").toString(); break;
                }
            }
            if (conversation_.isEmpty() && activeConversation_ != active) {
                messages_.clear(); clearStreams(); emit messagesChanged();
            }
            activeConversation_ = active; conversationKnown_ = true;
            emit changed(); loadMessages(request);
        });
}
bool OfficeController::accepts(const QVariantMap& message) const {
    return conversationKnown_ && !message.value("id").toString().isEmpty() &&
           message.value("agent_id") == selected_.value("id") &&
           message.value("conversation_id").toString() == viewedConversation();
}
void OfficeController::mergeMessage(const QVariantMap& message) {
    if (!accepts(message)) return;
    const auto found = std::find_if(messages_.begin(), messages_.end(), [&message](const QVariant& value) {
        return value.toMap().value("id") == message.value("id");
    });
    if (found == messages_.end()) messages_.append(message); else *found = message;
}
void OfficeController::cacheMessages() {
    if (!conversationKnown_ || selected_.isEmpty() || context_ != contextKey()) return;
    auto path = "/api/agents/" + selected_.value("id").toString() + "/chat";
    if (!viewedConversation().isEmpty()) path += "?conversation_id=" + QString::fromLatin1(QUrl::toPercentEncoding(viewedConversation()));
    cache_.write(cacheKey(path), QJsonDocument(QJsonObject{{"data", QJsonArray::fromVariantList(messages_)}}).toJson(QJsonDocument::Compact));
}
void OfficeController::loadMessages(quint64 request) {
    auto path = "/api/agents/" + selected_.value("id").toString() + "/chat";
    if (!viewedConversation().isEmpty()) path += "?conversation_id=" + QString::fromLatin1(QUrl::toPercentEncoding(viewedConversation()));
    get(path, &historyOwner_, [this, request] { return request == historyRequest_; }, [this](QJsonObject json) {
        messages_.clear();
        for (const auto& message : json.value("data").toArray()) mergeMessage(message.toObject().toVariantMap());
        // HTTP is an earlier snapshot: preserve channel messages received while it was in flight.
        for (const auto& message : realtimeMessages_) mergeMessage(message);
        std::stable_sort(messages_.begin(), messages_.end(), [](const QVariant& a, const QVariant& b) {
            return a.toMap().value("inserted_at").toString() < b.toMap().value("inserted_at").toString();
        });
        cacheMessages(); loading_ = false; emit messagesChanged(); emit changed();
    });
}
void OfficeController::closeChat() {
    if (!selected_.isEmpty()) drafts_[selected_.value("id").toString()] = draft_;
    invalidateChat(); selected_.clear(); draft_.clear(); conversations_.clear();
    conversation_.clear(); activeConversation_.clear(); conversationKnown_ = false; error_.clear();
    emit changed(); emit messagesChanged();
}
void OfficeController::setDraft(const QString& text) { draft_ = text.left(50000); emit changed(); }
bool OfficeController::hasDrafts() const {
    return !draft_.isEmpty() || std::any_of(drafts_.cbegin(), drafts_.cend(), [](const QString& draft) { return !draft.isEmpty(); });
}
void OfficeController::send(const QVariantList& driveItemIds) {
    contextChanged();
    if (sending_ || selected_.isEmpty() || (draft_.trimmed().isEmpty() && driveItemIds.isEmpty())) return;
    if (!conversation_.isEmpty()) { error_ = "Return to the current conversation to send this draft."; emit changed(); return; }
    if (!api_.context().online) { error_ = "Connect to Mokaid to send a message. Your draft is preserved."; emit changed(); return; }
    const auto generation = chatGeneration_; const auto submitted = draft_;
    sending_ = true; error_.clear(); emit changed();
    api_.request("POST", "/api/agents/" + selected_.value("id").toString() + "/chat",
        {{"body", draft_}, {"drive_item_ids", QJsonArray::fromVariantList(driveItemIds)}}, core::Scope::workspace, &mutationOwner_,
        [this, generation, submitted](ApiResponse response) {
            if (generation != chatGeneration_) return;
            sending_ = false;
            if (!response.ok()) { error_ = response.error; emit changed(); return; }
            if (draft_ == submitted) { draft_.clear(); drafts_.remove(selected_.value("id").toString()); }
            const auto message = response.json.value("data").toObject().toVariantMap();
            if (!message.value("id").toString().isEmpty()) realtimeMessages_.insert(message.value("id").toString(), message);
            refreshMessages(); emit changed();
        });
}
void OfficeController::selectConversation(const QString& id) {
    if (selected_.isEmpty() || (!id.isEmpty() && std::none_of(conversations_.cbegin(), conversations_.cend(), [&id](const QVariant& value) {
            return value.toMap().value("id").toString() == id;
        }))) return;
    invalidateChat(); conversation_ = id; loading_ = true; error_.clear();
    emit changed(); emit messagesChanged(); refreshMessages();
}
void OfficeController::newConversation() {
    contextChanged();
    const auto id = selected_.value("id").toString();
    if (id.isEmpty() || sending_) return;
    if (!api_.context().online) { error_ = "Connect to Mokaid to start a conversation."; emit changed(); return; }
    const auto generation = chatGeneration_;
    sending_ = true; emit changed();
    api_.request("POST", "/api/agents/" + id + "/conversations/new", {}, core::Scope::workspace, &mutationOwner_,
        [this, id, generation](ApiResponse response) {
            if (generation != chatGeneration_) return;
            sending_ = false;
            if (!response.ok()) { error_ = response.error; emit changed(); return; }
            selectAgent(id);
        });
}
void OfficeController::retireStream(const QString& id) {
    if (id.isEmpty() || retiredStreams_.contains(id)) return;
    retiredStreams_.insert(id); retiredOrder_.append(id);
    while (retiredOrder_.size() > maxRetiredStreams) retiredStreams_.remove(retiredOrder_.takeFirst());
}
void OfficeController::publishStreams() {
    QStringList parts;
    for (const auto& id : streamOrder_) if (!streams_.value(id).text.isEmpty()) parts.append(streams_.value(id).text);
    const auto text = parts.join("\n\n");
    if (stream_ != text) { stream_ = text; emit streamChanged(); }
}
void OfficeController::clearStreams() {
    for (const auto& id : streamOrder_) retireStream(id);
    streams_.clear(); streamOrder_.clear(); publishStream_.stop(); publishStreams();
    if (!streamNotice_.isEmpty()) { streamNotice_.clear(); emit changed(); }
}
void OfficeController::receive(const QString& topic, const QString& event, const QJsonObject& payload) {
    if (context_ != contextKey() || apiGeneration_ != api_.context().generation ||
        context_.isEmpty() || topic != "workspace:" + workspaceId()) return;
    if ((event.startsWith("agent.") || event == "task.assigned" || event == "task.completed" || event == "task.status_changed")
        && !debounceRefresh_.isActive()) debounceRefresh_.start();
    if (event.startsWith("task.")) {
        const auto taskId = payload.value("task_id").toString();
        const auto owner = std::find_if(agents_.cbegin(), agents_.cend(), [&taskId](const QVariant& value) {
            return !taskId.isEmpty() && value.toMap().value("current_task_id").toString() == taskId;
        });
        if (owner != agents_.cend()) {
            if (event == "task.tool_activity") {
                const auto agentId = payload.value("agent_id").toString();
                const auto runId = payload.value("run_id").toString();
                const auto incoming = payload.value("event").toObject();
                const auto eventId = incoming.value("id").toString();
                const auto currentRun = work_.value(taskId).value("latest_run").toMap().value("id").toString();
                if (agentId == owner->toMap().value("id").toString() && !runId.isEmpty() && !eventId.isEmpty()
                    && (currentRun.isEmpty() || currentRun == runId)) {
                    // Only display-safe event fields: never tool arguments, credentials or raw output.
                    QVariantMap detail;
                    for (const auto* key : {"id", "tool", "description", "status", "started_at", "finished_at"})
                        detail[key] = incoming.value(key).toString().left(1000);
                    if (!liveWorkEvents_.contains(runId) && liveWorkEvents_.size() >= 18) liveWorkEvents_.erase(liveWorkEvents_.begin());
                    auto& events = liveWorkEvents_[runId];
                    auto found = std::find_if(events.begin(), events.end(), [&eventId](const QVariant& value) {
                        return value.toMap().value("id").toString() == eventId;
                    });
                    if (found == events.end()) events.append(detail);
                    else if (preferLiveActivity(found->toMap(), detail)) *found = detail; else return;
                    while (events.size() > 32) events.removeFirst();
                    auto& task = work_[taskId];
                    auto run = task.value("latest_run").toMap();
                    auto history = run.value("tool_activity").toList();
                    auto existing = std::find_if(history.begin(), history.end(), [&eventId](const QVariant& value) {
                        return value.toMap().value("id").toString() == eventId;
                    });
                    if (existing == history.end()) history.append(detail);
                    else if (preferLiveActivity(existing->toMap(), detail)) *existing = detail; else return;
                    while (history.size() > 32) history.removeFirst();
                    run["id"] = runId; run["tool_activity"] = history; task["latest_run"] = run;
                    task["screen_connection"] = "live";
                    emit agentsChanged();
                    if (currentRun.isEmpty() && !workRefresh_.isActive()) workRefresh_.start();
                }
            } else if (!workRefresh_.isActive()) workRefresh_.start();
        }
    }
    if (selected_.isEmpty() || payload.value("agent_id").toString() != selected_.value("id").toString()) return;
    const auto id = payload.value("stream_id").toString();
    if (event == "agent_chat.message") {
        const auto message = payload.value("message").toObject().toVariantMap();
        if (message.value("agent_id") != selected_.value("id") || message.value("id").toString().isEmpty()) return;
        const auto envelopeConversation = payload.value("conversation_id").toString();
        if (!envelopeConversation.isEmpty() && envelopeConversation != message.value("conversation_id").toString()) return;
        if (realtimeMessages_.size() >= maxRealtimeMessages) realtimeMessages_.erase(realtimeMessages_.begin());
        realtimeMessages_.insert(message.value("id").toString(), message);
        if (!accepts(message)) {
            if (conversation_.isEmpty()) refreshMessages();
            return;
        }
        mergeMessage(message);
        cacheMessages();
        if (message.value("author_kind").toString() == "agent" && !id.isEmpty()) {
            retireStream(id); streams_.remove(id); streamOrder_.removeAll(id); publishStreams();
        }
        emit messagesChanged();
    } else if (event == "agent_chat.chunk") {
        // Old producers lack conversation identity. Display their canonical final message, never
        // guess that an unscoped fragment belongs to the currently open (possibly new) conversation.
        const auto conversation = payload.value("conversation_id").toString();
        if (!conversationKnown_ || conversation.isEmpty() || conversation != viewedConversation() ||
            id.isEmpty() || id.size() > 256 || retiredStreams_.contains(id)) return;
        bool evicted = false;
        if (!streams_.contains(id)) {
            if (streams_.size() >= maxStreams) {
                // A worker can disappear without a final/done event while the socket
                // remains connected. Reclaim only the oldest preview; its canonical
                // final message is still accepted and late deltas stay retired.
                const auto oldest = streamOrder_.takeFirst();
                retireStream(oldest); streams_.remove(oldest); evicted = true;
                streamNotice_ = "An older live response preview was hidden to keep this chat responsive. "
                    "Completed replies will still appear in message history.";
            }
            streams_.insert(id, {}); streamOrder_.append(id);
        }
        auto& stream = streams_[id];
        qsizetype total = 0;
        for (const auto& value : streams_) total += value.text.size();
        stream.text.append(payload.value("chunk").toString().left(std::max(qsizetype{0}, maxStreamCharacters - total)));
        if (!publishStream_.isActive()) publishStream_.start();
        if (payload.value("done").toBool()) {
            // 'done' isn't proof that a concurrent HTTP snapshot already contains the final message.
            // REST contains no stream_id. Identical replies can belong to different executions:
            // never finalize by text equality, even if only one candidate is currently visible.
            retireStream(id);
        }
        if (evicted || payload.value("done").toBool()) refreshMessages();
        if (evicted) emit changed();
    }
}
void OfficeController::reset() {
    ++generation_; ++agentsRequest_; api_.cancelRequests(&agentsOwner_); invalidateChat();
    drafts_.clear(); agents_.clear(); conversations_.clear(); selected_.clear();
    api_.cancelRequests(&workOwner_); work_.clear(); workRequests_.clear(); liveWorkEvents_.clear();
    workRefresh_.stop(); workPoll_.stop();
    retiredStreams_.clear(); retiredOrder_.clear();
    draft_.clear(); conversation_.clear(); activeConversation_.clear(); conversationKnown_ = false; error_.clear();
    context_ = contextKey(); apiGeneration_ = api_.context().generation;
    debounceRefresh_.stop(); emit agentsChanged(); emit changed(); emit messagesChanged();
}
}
