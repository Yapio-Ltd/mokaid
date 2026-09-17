#pragma once
#include <mokaid/application/artifact_service.hpp>
#include <mokaid/preview/resource_policy.hpp>
#include <mokaid/preview/native_file_preview.hpp>
#include <QHash>
#include <QSet>
#include <QTemporaryDir>
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
    Q_PROPERTY(QString kind READ kind CONSTANT)
    Q_PROPERTY(QString mimeType READ mimeType CONSTANT)
    Q_PROPERTY(QString sizeLabel READ sizeLabel CONSTANT)
    Q_PROPERTY(QVariantMap file READ file CONSTANT)
    Q_PROPERTY(QUrl imageSource READ imageSource CONSTANT)
    Q_PROPERTY(QUrl localSource READ localSource CONSTANT)
    Q_PROPERTY(QList<QWebEngineScript> scripts READ scripts CONSTANT)
public:
    PreviewDocument(const QVariantMap& file, QByteArray content);
    QQuickWebEngineProfile* profile() const { return profile_.get(); }
    QUrl url() const { return url_; }
    QString title() const { return title_; }
    QString version() const { return version_; }
    QString kind() const { return format_.value("kind").toString(); }
    QString mimeType() const { return format_.value("mimeType").toString(); }
    QString sizeLabel() const { return format_.value("sizeLabel").toString(); }
    QVariantMap file() const { return file_; }
    QUrl imageSource() const { return imageSource_; }
    QUrl localSource() const { return localSource_; }
    QList<QWebEngineScript> scripts() const { return scripts_; }
    Q_INVOKABLE bool internal(const QUrl& url) const { return policy_.internal(url) || policy_.pdfViewer(url); }
private:
    PreviewResourcePolicy policy_;
    QString title_, version_;
    QUrl url_;
    QVariantMap file_, format_;
    QUrl imageSource_, localSource_;
    QTemporaryDir localDirectory_;
    QList<QWebEngineScript> scripts_;
    std::unique_ptr<QQuickWebEngineProfile> profile_;
};

class PreviewController final : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList documents READ documents NOTIFY changed)
    Q_PROPERTY(int activeIndex READ activeIndex NOTIFY changed)
    Q_PROPERTY(quint64 openRevision READ openRevision NOTIFY changed)
    Q_PROPERTY(bool visible READ visible WRITE setVisible NOTIFY changed)
    Q_PROPERTY(bool loading READ loading NOTIFY changed)
    Q_PROPERTY(QString error READ error NOTIFY changed)
    Q_PROPERTY(QVariantMap failedFile READ failedFile NOTIFY changed)
    Q_PROPERTY(QVariantList collectionFiles READ collectionFiles NOTIFY changed)
    Q_PROPERTY(int collectionIndex READ collectionIndex NOTIFY changed)
    Q_PROPERTY(int collectionCount READ collectionCount NOTIFY changed)
    Q_PROPERTY(int thumbnailRevision READ thumbnailRevision NOTIFY thumbnailsChanged)
    Q_PROPERTY(bool nativePreviewAvailable READ nativePreviewAvailable CONSTANT)
public:
    explicit PreviewController(ArtifactService& artifacts, QObject* parent = nullptr);
    ~PreviewController() override;
    static void registerScheme(); // Must run before QGuiApplication.
    QVariantList documents() const;
    int activeIndex() const { return active_; }
    quint64 openRevision() const { return generation_; }
    bool visible() const { return visible_; }
    bool loading() const { return loading_; }
    QString error() const { return error_; }
    QVariantMap failedFile() const { return failedFile_; }
    QVariantList collectionFiles() const { return collection_; }
    int collectionIndex() const { return collectionIndex_; }
    int collectionCount() const { return static_cast<int>(collection_.size()); }
    int thumbnailRevision() const { return thumbnailRevision_; }
    bool nativePreviewAvailable() const { return NativeFilePreview::available(); }
    Q_INVOKABLE QVariantMap describe(const QVariantMap& file) const;
    Q_INVOKABLE QString thumbnailUrl(const QVariantMap& file);
    Q_INVOKABLE QString thumbnailState(const QVariantMap& file) const;
    Q_INVOKABLE void openFile(const QVariantMap& file);
    Q_INVOKABLE void openCollection(const QVariantList& files, int index = 0);
    Q_INVOKABLE void previous();
    Q_INVOKABLE void next();
    Q_INVOKABLE void downloadCurrent();
    Q_INVOKABLE void downloadFailed();
    Q_INVOKABLE void retryFailed();
    Q_INVOKABLE void openNativePreview();
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
    void downloadRequested(const QVariantMap& file);
    void thumbnailsChanged();
private:
    void loadFile(const QVariantMap& file);
    void fetchNextThumbnail();
    void restoreCollectionSelection();
    ArtifactService& artifacts_;
    NativeFilePreview nativePreview_;
    std::array<std::unique_ptr<PreviewDocument>, 2> documents_;
    std::array<QVariantMap, 2> files_;
    QVariantMap pending_;
    QVariantMap failedFile_;
    QByteArray pendingBytes_;
    QVariantList collection_;
    QHash<QString, QString> thumbnails_;
    std::unique_ptr<QTemporaryDir> thumbnailDirectory_;
    qint64 thumbnailBytes_{};
    QSet<QString> thumbnailPending_, thumbnailUnavailable_;
    QList<QVariantMap> thumbnailQueue_;
    int thumbnailActive_{}, thumbnailRevision_{}, collectionIndex_{};
    quint64 thumbnailGeneration_{};
    int active_{}, pendingIndex_{-1};
    quint64 generation_{};
    bool visible_{}, loading_{};
    QString error_;
};
}
