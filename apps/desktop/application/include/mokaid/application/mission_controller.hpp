#pragma once
#include <mokaid/application/activity_controller.hpp>
#include <QDateTime>
#include <QJsonArray>
#include <QSet>

namespace mokaid::desktop {
// A mission draft belongs to one authenticated workspace. Successful uploads
// are reused when editing a recommendation or retrying another attachment.
class MissionController final : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool opened READ opened NOTIFY changed)
    Q_PROPERTY(QString step READ step NOTIFY changed)
    Q_PROPERTY(bool busy READ busy NOTIFY changed)
    Q_PROPERTY(bool canLaunch READ canLaunch NOTIFY changed)
    Q_PROPERTY(bool hasDraft READ hasDraft NOTIFY changed)
    Q_PROPERTY(bool launchUncertain READ launchUncertain NOTIFY changed)
    Q_PROPERTY(QString error READ error NOTIFY changed)
    Q_PROPERTY(QString instruction READ instruction WRITE setInstruction NOTIFY changed)
    Q_PROPERTY(QVariantList attachments READ attachments NOTIFY changed)
    Q_PROPERTY(QVariantMap analysis READ analysis NOTIFY changed)
    Q_PROPERTY(QVariantList candidates READ candidates NOTIFY changed)
    Q_PROPERTY(QString selectedAgentId READ selectedAgentId NOTIFY changed)
    Q_PROPERTY(bool customSelected READ customSelected NOTIFY changed)
    Q_PROPERTY(QVariantMap customAgent READ customAgent NOTIFY changed)
    Q_PROPERTY(QVariantList grants READ grants NOTIFY changed)
    Q_PROPERTY(QVariantMap result READ result NOTIFY changed)
    Q_PROPERTY(QString capabilityWarning READ capabilityWarning NOTIFY changed)
    Q_PROPERTY(qint64 maximumFileBytes READ maximumFileBytes CONSTANT)
public:
    MissionController(ApiClient& api, SessionController& session, PhoenixClient& realtime,
                      ActivityController& activity, QObject* parent = nullptr);
    ~MissionController() override;
    bool opened() const { return opened_; }
    QString step() const { return step_; }
    bool busy() const { return step_ == "analyzing" || step_ == "launching" || uploading_; }
    bool canLaunch() const;
    bool hasDraft() const;
    bool launchUncertain() const { return launchUncertain_; }
    QString error() const { return error_; }
    QString instruction() const { return instruction_; }
    QVariantList attachments() const;
    QVariantMap analysis() const { return analysis_.toVariantMap(); }
    QVariantList candidates() const { return candidates_; }
    QString selectedAgentId() const { return selectedAgentId_; }
    bool customSelected() const { return customSelected_; }
    QVariantMap customAgent() const { return customAgent_.toVariantMap(); }
    QVariantList grants() const;
    QVariantMap result() const { return result_.toVariantMap(); }
    QString capabilityWarning() const;
    qint64 maximumFileBytes() const { return 49'000'000; }
    Q_INVOKABLE void begin(const QString& instruction = {});
    Q_INVOKABLE void beginInline(const QString& instruction = {});
    Q_INVOKABLE void beginForAgent(const QString& agentId, const QString& instruction = {});
    QVariantList roster() const { return agents_; }
    Q_INVOKABLE void close();
    Q_INVOKABLE void reset();
    Q_INVOKABLE void addFiles(const QVariantList& urls);
    Q_INVOKABLE void removeFile(const QString& id);
    Q_INVOKABLE void retryFile(const QString& id);
    Q_INVOKABLE void analyze();
    Q_INVOKABLE void edit();
    Q_INVOKABLE void selectAgent(const QString& id);
    Q_INVOKABLE void selectCustomAgent();
    Q_INVOKABLE void configureCustomAgent(const QString& name, const QString& role, const QString& instructions = {});
    Q_INVOKABLE void setGrant(const QString& id, bool allowed);
    Q_INVOKABLE void launch();
    Q_INVOKABLE void viewTask();
    void setInstruction(const QString& text);
signals:
    void changed();
    void launched(QString taskId, QString agentId);
    void completed(QVariantMap notification);
    void openTask(QString taskId);
private:
    struct Attachment {
        QString id, canonicalPath, name, mimeType, status{"queued"}, error;
        qint64 size{};
        QJsonObject uploaded;
    };
    void contextChanged();
    void openDraft(const QString& instruction, bool openSheet);
    QString contextKey() const;
    bool ready() const;
    bool current(quint64 epoch, quint64 generation, const QString& context) const;
    void loadAgents();
    void rebuildCandidates();
    void uploadNext();
    void uploadOne(const QString& id, bool continueAnalysis);
    void requestAnalysis();
    void consumeNotifications();
    void invalidateAnalysis();
    void fail(const QString& message);
    Attachment* attachment(const QString& id);
    ApiClient& api_;
    SessionController& session_;
    ActivityController& activity_;
    QObject draftOwner_, agentsOwner_;
    QList<Attachment> attachments_;
    QVariantList agents_, candidates_;
    QJsonObject analysis_, customAgent_, result_;
    QString context_, instruction_, selectedAgentId_, preferredAgentId_, error_, requestId_;
    QString step_{"describe"};
    QSet<QString> grants_, seenNotifications_, pendingNotifications_;
    QStringList notificationOrder_;
    QDateTime activatedAt_;
    quint64 epoch_{}, apiGeneration_{};
    bool opened_{}, customSelected_{}, uploading_{}, launchUncertain_{};
};
}
