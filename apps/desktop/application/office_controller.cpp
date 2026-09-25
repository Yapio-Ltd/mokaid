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
}
OfficeController::OfficeController(ApiClient& api, SessionController& session, PhoenixClient& realtime,
                                   CacheStore& cache, QObject* parent)
    : QObject(parent), api_(api), session_(session), realtime_(realtime), cache_(cache),
      context_(contextKey()), apiGeneration_(api.context().generation) {
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
    });
    connect(&realtime_, &PhoenixClient::connectionChanged, this, [this](bool connected) {
        if (!connected) clearStreams();
    });
    connect(&realtime_, &PhoenixClient::rejoined, this, [this] {
        clearStreams(); realtimeMessages_.clear(); refresh(); refreshMessages();
    });
    connect(&realtime_, &PhoenixClient::eventReceived, this, &OfficeController::receive);
}
OfficeController::~OfficeController() {
    api_.cancelRequests(&agentsOwner_); api_.cancelRequests(&historyOwner_); api_.cancelRequests(&mutationOwner_);
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
    });
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
    if (event.startsWith("agent.") && !debounceRefresh_.isActive()) debounceRefresh_.start();
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
    retiredStreams_.clear(); retiredOrder_.clear();
    draft_.clear(); conversation_.clear(); activeConversation_.clear(); conversationKnown_ = false; error_.clear();
    context_ = contextKey(); apiGeneration_ = api_.context().generation;
    debounceRefresh_.stop(); emit agentsChanged(); emit changed(); emit messagesChanged();
}
}
