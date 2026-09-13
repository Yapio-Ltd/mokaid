#include <mokaid/application/office_controller.hpp>
#include <QJsonDocument>
#include <QRegularExpression>
#include <QUrlQuery>
#include <algorithm>

namespace mokaid::desktop {
OfficeController::OfficeController(ApiClient& api, SessionController& session, PhoenixClient& realtime, CacheStore& cache, QObject* parent)
    : QObject(parent), api_(api), session_(session), realtime_(realtime), cache_(cache) {
    publishStream_.setSingleShot(true); publishStream_.setInterval(33);
    debounceRefresh_.setSingleShot(true); debounceRefresh_.setInterval(200);
    connect(&publishStream_, &QTimer::timeout, this, &OfficeController::streamChanged);
    connect(&debounceRefresh_, &QTimer::timeout, this, &OfficeController::refresh);
    connect(&session_, &SessionController::established, this, &OfficeController::refresh);
    connect(&session_, &SessionController::workspaceChanged, this, [this] { reset(); refresh(); });
    connect(&session_, &SessionController::cleared, this, &OfficeController::reset);
    connect(&realtime_, &PhoenixClient::rejoined, this, [this] { refresh(); refreshMessages(); });
    connect(&realtime_, &PhoenixClient::eventReceived, this, &OfficeController::receive);
}
QString OfficeController::cacheKey(const QString& path) const {
    return QString::fromStdString(core::cacheKey(api_.origin().toString().toStdString(),
        session_.user().value("id").toString().toStdString(), session_.workspaceId().toStdString(), path.toStdString()));
}
void OfficeController::get(const QString& path, std::function<void(QJsonObject)> done) {
    if (!session_.authenticated() || session_.workspaceId().isEmpty()) return;
    const auto key = cacheKey(path); const auto generation = generation_;
    auto fallback = [this, generation, key, done] {
        cache_.read(key, this, [this, generation, done](QByteArray bytes) {
            if (generation != generation_) return;
            if (bytes.isEmpty()) {
                loading_ = false;
                if (error_.isEmpty()) error_ = "No saved data is available for this view while offline.";
                emit changed(); return;
            }
            done(QJsonDocument::fromJson(bytes).object());
        });
    };
    if (!session_.online()) { fallback(); return; }
    api_.request("GET", path, {}, core::Scope::workspace, this,
        [this, generation, key, fallback, done = std::move(done)](ApiResponse response) {
            if (generation != generation_) return;
            if (!response.ok()) { error_ = response.error; loading_ = false; emit changed(); if (response.networkError) fallback(); return; }
            cache_.write(key, response.bytes); error_.clear(); done(std::move(response.json));
        });
}
void OfficeController::refresh() {
    get("/api/agents", [this](QJsonObject json) {
        auto agents = json.value("data").toArray().toVariantList();
        for (auto& value : agents) {
            auto record = value.toMap();
            record["name"] = record.value("display_name");
            const auto asset = record.value("avatar_cdn_path").toString();
            const auto match = QRegularExpression("avatar_(male|female|corporate|developer|design|finance|research|legal)(?:[._/]|$)").match(asset);
            record["asset_type"] = match.hasMatch() ? match.captured(1) : "male";
            if (record.value("id") == selected_.value("id")) selected_ = record;
            value = record;
        }
        agents_ = std::move(agents); emit agentsChanged(); emit changed();
    });
}
void OfficeController::selectAgent(const QString& id) {
    const auto found = std::find_if(agents_.begin(), agents_.end(), [&id](const QVariant& item) { return item.toMap().value("id").toString() == id; });
    if (found == agents_.end()) return;
    if (!selected_.isEmpty()) drafts_[selected_.value("id").toString()] = draft_;
    ++chatGeneration_; selected_ = found->toMap(); draft_ = drafts_.value(id);
    messages_.clear(); conversations_.clear(); conversation_.clear(); stream_.clear(); streamId_.clear();
    loading_ = true; error_.clear(); emit changed(); emit messagesChanged(); emit streamChanged();
    const auto generation = chatGeneration_;
    get("/api/agents/" + id + "/conversations", [this, generation](QJsonObject json) {
        if (generation != chatGeneration_) return;
        conversations_ = json.value("data").toArray().toVariantList(); emit changed();
    });
    refreshMessages();
    if (session_.online()) api_.request("POST", "/api/agents/" + id + "/chat/read", {}, core::Scope::workspace, this, [](ApiResponse) {});
}
void OfficeController::refreshMessages() {
    const auto id = selected_.value("id").toString(); if (id.isEmpty()) return;
    auto path = "/api/agents/" + id + "/chat";
    if (!conversation_.isEmpty()) path += "?conversation_id=" + QString::fromLatin1(QUrl::toPercentEncoding(conversation_));
    const auto generation = chatGeneration_;
    get(path, [this, generation](QJsonObject json) {
        if (generation != chatGeneration_) return;
        messages_ = json.value("data").toArray().toVariantList();
        loading_ = false; emit messagesChanged(); emit changed();
    });
}
void OfficeController::closeChat() {
    if (!selected_.isEmpty()) drafts_[selected_.value("id").toString()] = draft_;
    ++chatGeneration_; selected_.clear(); draft_.clear(); stream_.clear(); streamId_.clear();
    messages_.clear(); emit changed(); emit messagesChanged(); emit streamChanged();
}
void OfficeController::setDraft(const QString& text) { draft_ = text.left(50000); emit changed(); }
bool OfficeController::hasDrafts() const {
    if (!draft_.isEmpty()) return true;
    return std::any_of(drafts_.begin(), drafts_.end(), [](const QString& draft) { return !draft.isEmpty(); });
}
void OfficeController::send(const QVariantList& driveItemIds) {
    if (sending_ || selected_.isEmpty() || (draft_.trimmed().isEmpty() && driveItemIds.isEmpty())) return;
    if (!conversation_.isEmpty()) { error_ = "Return to the current conversation to send this draft."; emit changed(); return; }
    if (!session_.online()) { error_ = "Connect to Mokaid to send a message. Your draft is preserved."; emit changed(); return; }
    const auto id = selected_.value("id").toString();
    const auto generation = chatGeneration_; const auto submitted = draft_;
    sending_ = true; error_.clear(); emit changed();
    api_.request("POST", "/api/agents/" + id + "/chat", {{"body", draft_}, {"drive_item_ids", QJsonArray::fromVariantList(driveItemIds)}},
        core::Scope::workspace, this, [this, generation, submitted](ApiResponse response) {
            sending_ = false;
            if (generation != chatGeneration_) { emit changed(); return; }
            if (!response.ok()) { error_ = response.error; emit changed(); return; }
            if (draft_ == submitted) { draft_.clear(); drafts_.remove(selected_.value("id").toString()); }
            refreshMessages(); emit changed();
        });
}
void OfficeController::selectConversation(const QString& id) {
    if (!id.isEmpty() && std::none_of(conversations_.begin(), conversations_.end(), [&id](const QVariant& v) { return v.toMap().value("id").toString() == id; })) return;
    ++chatGeneration_; conversation_ = id; stream_.clear(); streamId_.clear(); loading_ = true;
    emit changed(); emit streamChanged(); refreshMessages();
}
void OfficeController::newConversation() {
    const auto id = selected_.value("id").toString(); if (id.isEmpty() || sending_) return;
    api_.request("POST", "/api/agents/" + id + "/conversations/new", {}, core::Scope::workspace, this,
        [this, id](ApiResponse response) {
            if (!response.ok()) { error_ = response.error; emit changed(); return; }
            if (id == selected_.value("id").toString()) selectAgent(id);
        });
}
void OfficeController::receive(const QString&, const QString& event, const QJsonObject& payload) {
    if (event.startsWith("agent.") && !debounceRefresh_.isActive()) debounceRefresh_.start();
    if (payload.value("agent_id").toString() != selected_.value("id").toString() || selected_.isEmpty()) return;
    if (event == "agent_chat.message") {
        const auto message = payload.value("message").toObject().toVariantMap();
        if (!conversation_.isEmpty() && message.value("conversation_id").toString() != conversation_) return;
        const auto exists = std::any_of(messages_.begin(), messages_.end(), [&message](const QVariant& item) { return item.toMap().value("id") == message.value("id"); });
        if (!exists) messages_.append(message);
        if (message.value("author_kind").toString() == "agent") { stream_.clear(); streamId_.clear(); emit streamChanged(); }
        emit messagesChanged();
    } else if (event == "agent_chat.chunk" && conversation_.isEmpty()) {
        const auto id = payload.value("stream_id").toString(); if (id.isEmpty()) return;
        if (streamId_ != id) { streamId_ = id; stream_.clear(); }
        stream_.append(payload.value("chunk").toString());
        if (stream_.size() > 1000000) stream_ = stream_.left(1000000);
        if (!publishStream_.isActive()) publishStream_.start();
        if (payload.value("done").toBool()) { stream_.clear(); streamId_.clear(); refreshMessages(); }
    }
}
void OfficeController::reset() {
    ++generation_; ++chatGeneration_; drafts_.clear(); agents_.clear(); messages_.clear(); conversations_.clear(); selected_.clear();
    draft_.clear(); stream_.clear(); streamId_.clear(); conversation_.clear(); error_.clear(); loading_ = false; sending_ = false;
    debounceRefresh_.stop(); publishStream_.stop(); emit agentsChanged(); emit changed(); emit messagesChanged(); emit streamChanged();
}
}
