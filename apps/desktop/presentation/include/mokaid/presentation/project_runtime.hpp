#pragma once
#include <QObject>
#include <QProcess>
#include <QNetworkAccessManager>
#include <QPointer>
#include <QTimer>
#include <QUrl>

namespace mokaid::desktop {
// Local execution is initiated only by an explicit user action on an inspected folder.
class ProjectRuntime final : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString folder READ folder NOTIFY changed)
    Q_PROPERTY(QString name READ name NOTIFY changed)
    Q_PROPERTY(QString state READ state NOTIFY changed)
    Q_PROPERTY(QString error READ error NOTIFY changed)
    Q_PROPERTY(QString output READ output NOTIFY changed)
    Q_PROPERTY(QUrl url READ url NOTIFY changed)
    Q_PROPERTY(bool busy READ busy NOTIFY changed)
public:
    explicit ProjectRuntime(QObject* parent = nullptr);
    ~ProjectRuntime() override;
    QString folder() const { return folder_; }
    QString name() const { return name_; }
    QString state() const { return state_; }
    QString error() const { return error_; }
    QString output() const { return output_; }
    QUrl url() const { return state_ == "running" ? QUrl("http://127.0.0.1:3000") : QUrl{}; }
    bool busy() const { return state_ == "installing" || state_ == "starting" || state_ == "running" || state_ == "stopping"; }
    Q_INVOKABLE void inspect(const QUrl& folder);
    Q_INVOKABLE void start(bool installDependencies);
    Q_INVOKABLE void stop();
    Q_INVOKABLE void openBrowser();
    Q_INVOKABLE void clear();
signals:
    void changed();
private:
    void execute(const QStringList& arguments);
    bool checkPort();
    void launchDev();
    void fail(const QString& message);
    void appendOutput(const QByteArray& bytes);
    void probe();
    void cancelProbe();
    void stopTree(bool force);
    QProcess process_;
    QNetworkAccessManager network_;
    QPointer<QNetworkReply> probeReply_;
    QTimer probeTimer_, deadline_, killTimer_;
    QString folder_, name_, state_{"empty"}, error_, output_, framework_, node_, npm_;
    bool stopping_{}, failed_{};
    quint64 generation_{};
    qint64 processGroup_{};
};
}
