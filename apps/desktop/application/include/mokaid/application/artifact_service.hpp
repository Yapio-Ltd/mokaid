#pragma once
#include <mokaid/application/session_controller.hpp>
#include <mokaid/storage/cache_store.hpp>

namespace mokaid::desktop {
struct ArtifactResult { QByteArray bytes; QString error; };
// Owns authenticated artifact access. WebEngine receives content, never session credentials.
class ArtifactService final : public QObject {
    Q_OBJECT
public:
    using Completion = std::function<void(ArtifactResult)>;
    ArtifactService(ApiClient&, SessionController&, CacheStore&, QObject* parent = nullptr);
    void fetch(const QString& id, QObject* owner, Completion completion);
    QUrl browserFilesUrl() const;
private:
    ApiClient& api_;
    SessionController& session_;
    CacheStore& cache_;
    quint64 generation_{};
};
}
