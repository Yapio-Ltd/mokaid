#include <mokaid/features/avatar_generation_controller.hpp>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>

namespace mokaid::desktop {
namespace {
bool pending(const QVariantMap& job) {
    const auto status = job.value("status").toString();
    return !status.isEmpty() && status != "ready" && status != "failed" && status != "cancelled";
}
}
AvatarGenerationController::AvatarGenerationController(ApiClient& api, SessionController& session, QObject* parent)
    : QObject(parent), api_(api), poll_(this), contextGeneration_(api.context().generation) {
    poll_.setInterval(5000);
    connect(&poll_, &QTimer::timeout, this, &AvatarGenerationController::refreshCurrent);
    connect(&session, &SessionController::workspaceChanged, this, &AvatarGenerationController::syncContext);
    connect(&session, &SessionController::changed, this, &AvatarGenerationController::syncContext);
    connect(&session, &SessionController::cleared, this, &AvatarGenerationController::syncContext);
    connect(&api, &ApiClient::onlineChanged, this, [this] {
        syncContext(); emit changed();
        if (online() && pending(current_)) refreshCurrent();
    });
}
AvatarGenerationController::~AvatarGenerationController() {
    api_.cancelRequests(&listOwner_); api_.cancelRequests(&submitOwner_); api_.cancelRequests(&pollOwner_);
}
void AvatarGenerationController::syncContext() {
    if (contextGeneration_ == api_.context().generation) return;
    contextGeneration_ = api_.context().generation; ++epoch_;
    api_.cancelRequests(&listOwner_); api_.cancelRequests(&submitOwner_); api_.cancelRequests(&pollOwner_);
    poll_.stop(); catalog_.clear(); generations_.clear(); current_.clear(); error_.clear();
    submitting_ = refreshing_ = polling_ = false; emit changed();
}
bool AvatarGenerationController::available() {
    syncContext();
    if (core::mayRequest(api_.context(), core::Scope::workspace, true)) return true;
    error_ = "Connect to your workspace to create a character. Your draft stays here."; emit changed(); return false;
}
void AvatarGenerationController::refresh() {
    if (!available() || refreshing_) return;
    refreshing_ = true; error_.clear(); emit changed();
    const auto epoch = epoch_;
    api_.request("GET", "/api/assets-3d?kind=character", {}, core::Scope::identity, &listOwner_,
        [this, epoch](ApiResponse response) {
            if (epoch != epoch_) return;
            if (response.ok()) catalog_ = response.json.value("data").toArray().toVariantList();
            else error_ = response.error;
            emit changed();
        });
    api_.request("GET", "/api/avatar-generations", {}, core::Scope::workspace, &listOwner_,
        [this, epoch](ApiResponse response) {
            if (epoch != epoch_) return;
            refreshing_ = false;
            if (response.ok()) {
                generations_ = response.json.value("data").toArray().toVariantList();
                const auto selectedId = current_.value("id").toString();
                for (const auto& value : generations_) {
                    const auto job = value.toMap();
                    if ((!selectedId.isEmpty() && job.value("id").toString() == selectedId) ||
                        (selectedId.isEmpty() && pending(job))) { accept(QJsonObject::fromVariantMap(job)); break; }
                }
            } else error_ = response.error;
            emit changed();
        });
}
void AvatarGenerationController::generateText(const QString& prompt, const QString& name) {
    if (submitting_ || !available()) return;
    const auto text = prompt.trimmed();
    if (text.size() < 3 || text.size() > 600) { error_ = "Describe your character in 3–600 characters."; emit changed(); return; }
    QJsonObject body{{"mode", "text"}, {"prompt", text}};
    if (!name.trimmed().isEmpty()) body.insert("name", name.trimmed().left(80));
    submit(body);
}
void AvatarGenerationController::generateImage(const QUrl& url, const QString& name) {
    if (submitting_ || !available()) return;
    const QFileInfo info(url.toLocalFile());
    QFile file(info.absoluteFilePath());
    if (!url.isLocalFile() || !info.isFile() || info.size() <= 0 || info.size() > 10000000 || !file.open(QIODevice::ReadOnly)) {
        error_ = "Choose a local PNG or JPEG image up to 10 MB."; emit changed(); return;
    }
    const auto bytes = file.read(12);
    if (!(bytes.startsWith(QByteArray::fromHex("89504e470d0a1a0a")) || bytes.startsWith(QByteArray::fromHex("ffd8ff")))) {
        error_ = "This file is not a PNG or JPEG image. Choose another photo."; emit changed(); return;
    }
    QJsonObject body{{"mode", "image"}};
    if (!name.trimmed().isEmpty()) body.insert("name", name.trimmed().left(80));
    submit(body, url);
}
void AvatarGenerationController::submit(const QJsonObject& body, const QUrl& file) {
    submitting_ = true; error_.clear(); emit changed();
    const auto epoch = epoch_;
    auto done = [this, epoch](ApiResponse response) {
        if (epoch != epoch_) return;
        submitting_ = false;
        if (!response.ok()) {
            error_ = response.networkError ? "The connection was interrupted. Refresh your creations before trying again to avoid generating twice." : response.error;
            emit changed(); return;
        }
        accept(response.json.value("data").toObject());
    };
    if (file.isEmpty()) api_.request("POST", "/api/avatar-generations", body, core::Scope::workspace, &submitOwner_, std::move(done));
    else api_.upload("/api/avatar-generations", {file}, body, core::Scope::workspace, &submitOwner_, std::move(done));
}
void AvatarGenerationController::accept(const QJsonObject& data) {
    const auto job = data.toVariantMap();
    if (job.value("id").toString().isEmpty()) { error_ = "The character response was incomplete. Refresh your creations."; emit changed(); return; }
    current_ = job;
    bool found = false;
    for (auto& value : generations_) if (value.toMap().value("id") == job.value("id")) { value = job; found = true; break; }
    if (!found) generations_.prepend(job);
    if (pending(job)) poll_.start(); else poll_.stop();
    emit changed();
}
void AvatarGenerationController::selectGeneration(const QString& id) {
    syncContext();
    for (const auto& value : generations_) if (value.toMap().value("id").toString() == id) {
        error_.clear(); accept(QJsonObject::fromVariantMap(value.toMap()));
        if (pending(current_)) refreshCurrent(); return;
    }
}
void AvatarGenerationController::refreshCurrent() {
    syncContext();
    const auto id = current_.value("id").toString();
    if (id.isEmpty() || polling_ || !online()) return;
    polling_ = true;
    const auto epoch = epoch_;
    api_.request("GET", "/api/avatar-generations/" + QString::fromLatin1(QUrl::toPercentEncoding(id)), {}, core::Scope::workspace, &pollOwner_,
        [this, epoch, id](ApiResponse response) {
            if (epoch != epoch_) return;
            polling_ = false;
            if (current_.value("id").toString() != id) return;
            if (response.ok()) { error_.clear(); accept(response.json.value("data").toObject()); }
            else { error_ = response.error; emit changed(); }
        });
}
void AvatarGenerationController::clearCurrent() {
    syncContext(); poll_.stop(); api_.cancelRequests(&pollOwner_); polling_ = false;
    current_.clear(); error_.clear(); emit changed();
}
}
