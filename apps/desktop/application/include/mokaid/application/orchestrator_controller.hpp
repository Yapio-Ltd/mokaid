#pragma once
#include <mokaid/application/mission_controller.hpp>
#include <mokaid/storage/cache_store.hpp>
#include <QTimer>

namespace mokaid::desktop {
// Conversations are kept per origin/user/workspace. The active thread is the
// only history sent to /api/orchestrator/chat. A brief is assigned through
// MissionController's idempotent dispatch. An existing agent with no pending
// integration grant starts on its own; grants and new specialists wait for confirm.
class OrchestratorController final : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList messages READ messages NOTIFY changed)
    Q_PROPERTY(QVariantList conversations READ conversations NOTIFY changed)
    Q_PROPERTY(QString activeConversationId READ activeConversationId NOTIFY changed)
    Q_PROPERTY(QVariantList missions READ missions NOTIFY changed)
    Q_PROPERTY(bool busy READ busy NOTIFY changed)
    Q_PROPERTY(bool refreshing READ refreshing NOTIFY changed)
    Q_PROPERTY(bool ready READ ready NOTIFY changed)
    Q_PROPERTY(QString error READ error NOTIFY changed)
    Q_PROPERTY(QString draft READ draft WRITE setDraft NOTIFY changed)
    Q_PROPERTY(QString language READ language WRITE setLanguage NOTIFY changed)
    Q_PROPERTY(QString pendingInstruction READ pendingInstruction NOTIFY changed)
    Q_PROPERTY(QString assignmentPhase READ assignmentPhase NOTIFY changed)
    Q_PROPERTY(QString assignmentAgentId READ assignmentAgentId NOTIFY changed)
    Q_PROPERTY(QString assignmentTaskId READ assignmentTaskId NOTIFY changed)
    Q_PROPERTY(QVariantList assignmentAgents READ assignmentAgents NOTIFY changed)
public:
    OrchestratorController(ApiClient&, SessionController&, PhoenixClient&, CacheStore&, MissionController&, QObject* parent = nullptr);
    ~OrchestratorController() override;
    QVariantList messages() const { return messages_; }
    QVariantList conversations() const { return conversations_; }
    QString activeConversationId() const { return activeId_; }
    QVariantList missions() const { return missions_; }
    bool busy() const { return busy_; }
    bool refreshing() const { return refreshing_; }
    bool ready() const;
    QString error() const { return error_; }
    QString draft() const { return draft_; }
    QString language() const { return language_; }
    QString pendingInstruction() const { return pendingInstruction_; }
    QString assignmentPhase() const { return assignmentPhase_; }
    QString assignmentAgentId() const { return assignmentAgentId_; }
    QString assignmentTaskId() const { return assignmentTaskId_; }
    QVariantList assignmentAgents() const { return assignmentAgents_; }
    void setDraft(const QString&);
    void setLanguage(const QString&);
    Q_INVOKABLE void sendMessage(const QString& text = {}, const QString& language = {});
    Q_INVOKABLE void refresh();
    Q_INVOKABLE void prepareMission();
    Q_INVOKABLE void confirmAssignment();
    Q_INVOKABLE void cancelMission(const QString& id);
    Q_INVOKABLE void reviewMission(const QString& id);
    Q_INVOKABLE void clearConversation();
    Q_INVOKABLE void newConversation();
    Q_INVOKABLE void openConversation(const QString& id);
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
    void rememberActive();
    QString earlierWorkRequest() const;
    QString assignmentReply(const QString& reply) const;
    void resumeAutomaticAssignment();
    void assignInline();
    void syncAssignment();
    void scheduleLaunch();
    void clearAssignment();
    QString messageLanguage(const QString& text) const;
    ApiClient& api_;
    SessionController& session_;
    CacheStore& cache_;
    MissionController& mission_;
    QObject chatOwner_, missionsOwner_, mutationOwner_;
    QTimer refreshTimer_, eventTimer_;
    QVariantList messages_, conversations_, missions_, assignmentAgents_;
    QString context_, activeId_, draft_, language_, pendingInstruction_, error_;
    QString assignmentPhase_, assignmentAgentId_, assignmentTaskId_;
    QSet<QString> stopping_;
    quint64 epoch_{}, apiGeneration_{}, revision_{};
    bool busy_{}, refreshing_{}, inlineAssign_{}, autoLaunchAttempted_{};
};
}
