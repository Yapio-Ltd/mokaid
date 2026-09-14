#pragma once
#include <mokaid/application/artifact_service.hpp>
#include <mokaid/preview/resource_policy.hpp>
#include <QQuickWebEngineProfile>
#include <QWebEngineScript>
#include <QVariantList>
#include <array>
#include <memory>

namespace mokaid::desktop {
class PreviewDocument final : public QObject {
    Q_OBJECT
    Q_PROPERTY(QQuickWebEngineProfile* profile READ profile CONSTANT)
    Q_PROPERTY(QUrl url READ url CONSTANT)
    Q_PROPERTY(QString title READ title CONSTANT)
    Q_PROPERTY(QString version READ version CONSTANT)
    Q_PROPERTY(QList<QWebEngineScript> scripts READ scripts CONSTANT)
public:
    PreviewDocument(const QVariantMap& file, QByteArray content);
    QQuickWebEngineProfile* profile() const { return profile_.get(); }
    QUrl url() const { return url_; }
    QString title() const { return title_; }
    QString version() const { return version_; }
    QList<QWebEngineScript> scripts() const { return scripts_; }
    Q_INVOKABLE bool internal(const QUrl& url) const { return policy_.internal(url); }
private:
    PreviewResourcePolicy policy_;
    QString title_, version_;
    QUrl url_;
    QList<QWebEngineScript> scripts_;
    std::unique_ptr<QQuickWebEngineProfile> profile_;
};

class PreviewController final : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList documents READ documents NOTIFY changed)
    Q_PROPERTY(int activeIndex READ activeIndex NOTIFY changed)
    Q_PROPERTY(bool visible READ visible WRITE setVisible NOTIFY changed)
    Q_PROPERTY(bool loading READ loading NOTIFY changed)
    Q_PROPERTY(QString error READ error NOTIFY changed)
public:
    explicit PreviewController(ArtifactService& artifacts, QObject* parent = nullptr);
    static void registerScheme(); // Must run before QGuiApplication.
    QVariantList documents() const;
    int activeIndex() const { return active_; }
    bool visible() const { return visible_; }
    bool loading() const { return loading_; }
    QString error() const { return error_; }
    Q_INVOKABLE void openFile(const QVariantMap& file);
    // UI destroys the previous WebEngineView first, then calls this on the next event-loop turn.
    Q_INVOKABLE void commitOpen();
    Q_INVOKABLE void cancelOpen();
    Q_INVOKABLE void activate(int index);
    Q_INVOKABLE void setVisible(bool visible);
    Q_INVOKABLE void openExternal(const QUrl& url);
    Q_INVOKABLE void clear();
    Q_INVOKABLE void commitClear();
signals:
    void changed();
    void replacementRequested(int index);
    void clearViewsRequested();
private:
    ArtifactService& artifacts_;
    std::array<std::unique_ptr<PreviewDocument>, 2> documents_;
    std::array<QVariantMap, 2> files_;
    QVariantMap pending_;
    QByteArray pendingBytes_;
    int active_{}, pendingIndex_{-1};
    quint64 generation_{};
    bool visible_{}, loading_{};
    QString error_;
};
}
