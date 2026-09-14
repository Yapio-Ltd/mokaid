#include <mokaid/application/artifact_service.hpp>
#include <QPointer>
#include <QRegularExpression>

namespace mokaid::desktop {
ArtifactService::ArtifactService(ApiClient& api, SessionController& session, CacheStore& cache, QObject* parent)
    : QObject(parent), api_(api), session_(session), cache_(cache) {
    connect(&session_, &SessionController::cleared, this, [this] { ++generation_; });
    connect(&session_, &SessionController::workspaceChanged, this, [this] { ++generation_; });
}
void ArtifactService::fetch(const QString& id, QObject* owner, Completion completion) {
    static const QRegularExpression validId("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$");
    if (!validId.match(id).hasMatch() || !session_.authenticated() || session_.workspaceId().isEmpty()) {
        completion({{}, "A valid deliverable and workspace session are required."}); return;
    }
    const auto path = "/api/drive/" + id + "/raw";
    const auto key = QString::fromStdString(core::cacheKey(api_.origin().toString().toStdString(),
        session_.user().value("id").toString().toStdString(), session_.workspaceId().toStdString(), path.toStdString()));
    const auto generation = generation_;
    const auto guard = QPointer<QObject>(owner);
    auto fallback = [this, key, generation, guard, completion] {
        cache_.read(key, this, [this, generation, guard, completion](QByteArray bytes) {
            if (!guard || generation != generation_) return;
            const auto error = bytes.isEmpty() ? QStringLiteral("This deliverable is not available in the offline cache.") : QString{};
            completion({std::move(bytes), error});
        });
    };
    if (!session_.online()) { fallback(); return; }
    api_.getBytes(path, core::Scope::workspace, owner,
        [this, key, guard, generation, fallback, completion = std::move(completion)](ApiResponse response) {
            if (!guard || generation != generation_) return;
            if (response.networkError) { fallback(); return; }
            if (!response.ok()) { completion({{}, response.error}); return; }
            if (response.bytes.size() <= 8 * 1024 * 1024) cache_.write(key, response.bytes);
            completion({std::move(response.bytes), {}});
        });
}
}
