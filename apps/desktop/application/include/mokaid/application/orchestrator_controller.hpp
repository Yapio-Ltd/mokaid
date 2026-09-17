#pragma once
#include <mokaid/application/mission_controller.hpp>
#include <mokaid/storage/cache_store.hpp>
#include <QTimer>

namespace mokaid::desktop {
// One conversation per origin/user/workspace. Model replies can propose a
// mission, but only MissionController's reviewed, idempotent dispatch can run it.
class OrchestratorController final : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList messages READ messages NOTIFY changed)
    Q_PROPERTY(QVariantList missions READ missions NOTIFY changed)
    Q_PROPERTY(bool busy READ busy NOTIFY changed)
    Q_PROPERTY(bool refreshing READ refreshing NOTIFY changed)
    Q_PROPERTY(bool ready READ ready NOTIFY changed)
    Q_PROPERTY(QString error READ error NOTIFY changed)
    Q_PROPERTY(QString draft READ draft WRITE setDraft NOTIFY changed)
    Q_PROPERTY(QString language READ language WRITE setLanguage NOTIFY changed)
    Q_PROPERTY(QString pendingInstruction READ pendingInstruction NOTIFY changed)
public:
    OrchestratorController(ApiClient&, SessionController&, PhoenixClient&, CacheStore&, MissionController&, QObject* parent = nullptr);
    ~OrchestratorController() override;
    QVariantList messages() const { return messages_; }
    QVariantList missions() const { return missions_; }
    bool busy() const { return busy_; }
    bool refreshing() const { return refreshing_; }
    bool ready() const;
    QString error() const { return error_; }
    QString draft() const { return draft_; }
    QString language() const { return language_; }
    QString pendingInstruction() const { return pendingInstruction_; }
    void setDraft(const QString&);
    void setLanguage(const QString&);
    Q_INVOKABLE void sendMessage(const QString& text = {}, const QString& language = {});
    Q_INVOKABLE void refresh();
    Q_INVOKABLE void prepareMission();
    Q_INVOKABLE void cancelMission(const QString& id);
    Q_INVOKABLE void reviewMission(const QString& id);
    Q_INVOKABLE void clearConversation();
signals:
    void changed();
    void assistantReplied(QString text, QString language);
    void openTask(QString id);
private:
    QString contextKey() const;
    void contextChanged();
    void persist();
    void restore();
    bool current(quint64 epoch, quint64 generation, const QString& context) const;
    bool knownTask(const QString& id) const;
    void append(const QString& role, const QString& text, const QString& taskId = {});
    ApiClient& api_;
    SessionController& session_;
    CacheStore& cache_;
    MissionController& mission_;
    QObject chatOwner_, missionsOwner_, mutationOwner_;
    QTimer refreshTimer_, eventTimer_;
    QVariantList messages_, missions_;
    QString context_, draft_, language_, pendingInstruction_, error_;
    QSet<QString> stopping_;
    quint64 epoch_{}, apiGeneration_{}, revision_{};
    bool busy_{}, refreshing_{};
};
}
