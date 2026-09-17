#include <mokaid/preview/preview_controller.hpp>
#include <mokaid/preview/document_format.hpp>
#include <QBuffer>
#include <QDesktopServices>
#include <QCryptographicHash>
#include <QFile>
#include <QFileInfo>
#include <QFutureWatcher>
#include <QImageReader>
#include <QRegularExpression>
#include <QTimer>
#include <QUuid>
#include <QtConcurrentRun>
#include <QWebEngineUrlRequestInfo>
#include <QWebEngineUrlRequestInterceptor>
#include <QWebEngineUrlRequestJob>
#include <QWebEngineUrlScheme>
#include <QWebEngineUrlSchemeHandler>

namespace mokaid::desktop {
namespace {
class ResourceInterceptor final : public QWebEngineUrlRequestInterceptor {
public:
    ResourceInterceptor(PreviewResourcePolicy policy, QObject* parent)
        : QWebEngineUrlRequestInterceptor(parent), policy_(std::move(policy)) {}
    void interceptRequest(QWebEngineUrlRequestInfo& info) override {
        const auto& url = info.requestUrl();
        using Info = QWebEngineUrlRequestInfo;
        const bool internal = policy_.internal(url);
        bool allowed = (internal || policy_.pdfResource(url)) && (info.requestMethod() == "GET" || info.requestMethod() == "HEAD");
        if (!policy_.pdfDocument && info.requestMethod() == "GET") {
            switch (info.resourceType()) {
            case Info::ResourceTypeScript: allowed |= policy_.remote(url, policy_.scriptHosts); break;
            case Info::ResourceTypeStylesheet: allowed |= policy_.remote(url, policy_.styleHosts); break;
            case Info::ResourceTypeFontResource: allowed |= policy_.remote(url, policy_.fontHosts) || url.scheme() == "data"; break;
            case Info::ResourceTypeImage: allowed |= policy_.remote(url, policy_.imageHosts) || url.scheme() == "data" || url.scheme() == "blob"; break;
            default: break;
            }
        }
        // Even redirects from an allowed CDN are checked again. No credentials or referrer escape.
        info.setHttpHeader("Referer", "");
        info.setHttpHeader("Authorization", "");
        info.setHttpHeader("X-Mokaid-Authorization", "");
        info.block(!allowed);
    }
private:
    const PreviewResourcePolicy policy_;
};
class DocumentScheme final : public QWebEngineUrlSchemeHandler {
public:
    DocumentScheme(PreviewResourcePolicy policy, QByteArray bytes, QByteArray mime, QByteArray page, QObject* parent)
        : QWebEngineUrlSchemeHandler(parent), policy_(std::move(policy)), bytes_(std::move(bytes)), mime_(std::move(mime)), page_(std::move(page)) {}
    void requestStarted(QWebEngineUrlRequestJob* job) override {
        if (!policy_.internal(job->requestUrl()) || job->requestMethod() != "GET") {
            job->fail(QWebEngineUrlRequestJob::RequestDenied); return;
        }
        const auto path = job->requestUrl().path();
        if (path != "/index.html" && path != "/original" && path != "/document.pdf") {
            job->fail(QWebEngineUrlRequestJob::UrlNotFound); return;
        }
        job->setAdditionalResponseHeaders({{"Content-Security-Policy", policy_.csp()},
            {"X-Content-Type-Options", "nosniff"}, {"Referrer-Policy", "no-referrer"},
            {"Cache-Control", "no-store"}, {"Permissions-Policy", "camera=(), microphone=(), geolocation=(), usb=(), payment=()"}});
        auto buffer = std::make_unique<QBuffer>();
        const bool wrapper = path == "/index.html" && !page_.isEmpty();
        buffer->setData(wrapper ? page_ : bytes_); buffer->open(QIODevice::ReadOnly);
        buffer->setParent(job); job->reply(wrapper ? QByteArray("text/html") : mime_, buffer.release());
    }
private:
    const PreviewResourcePolicy policy_;
    const QByteArray bytes_, mime_, page_;
};
bool validId(const QString& id) {
    static const QRegularExpression pattern("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$");
    return pattern.match(id).hasMatch();
}
QString thumbnailKey(const QVariantMap& file) {
    return file.value("id").toString() + ':' + file.value("version").toString() + ':' + file.value("updated_at").toString();
}
}
PreviewDocument::PreviewDocument(const QVariantMap& file, QByteArray content)
    : title_(file.value("name").toString()), version_(file.value("version").toString()),
      file_(normalizeDeliverable(file)), format_(describeDeliverable(file)),
      profile_(std::make_unique<QQuickWebEngineProfile>()) {
    title_ = file_.value("name").toString();
    file_.insert("size_bytes", content.size());
    format_ = describeDeliverable(file_);
    policy_.host = QUuid::createUuid().toString(QUuid::WithoutBraces);
    policy_.pdfDocument = kind() == "pdf";
    url_ = QUrl("mokaid-preview://" + policy_.host + (kind() == "pdf" ? "/document.pdf" : "/index.html"));
    if (localDirectory_.isValid()) {
        auto suffix = QFileInfo(title_).suffix().left(24);
        suffix.remove(QRegularExpression("[^a-zA-Z0-9]"));
        auto base = QFileInfo(title_).completeBaseName().left(120);
        base.replace(QRegularExpression("[^\\p{L}\\p{N}._ -]"), "_");
        if (base.isEmpty() || base == "." || base == "..") base = "deliverable";
        QFile original(localDirectory_.filePath(base + (suffix.isEmpty() ? QString{} : '.' + suffix)));
        if (original.open(QIODevice::WriteOnly)) {
            original.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
            if (original.write(content) == content.size()) localSource_ = QUrl::fromLocalFile(original.fileName());
        }
    }
    if (kind() == "image" && localSource_.isLocalFile()) {
        QImageReader image(localSource_.toLocalFile());
        const auto size = image.size();
        if (image.canRead() && size.isValid() && static_cast<qint64>(size.width()) * size.height() <= 32 * 1024 * 1024)
            imageSource_ = localSource_;
    }
    QWebEngineScript activity;
    activity.setName("Mokaid isolated activity tracker");
    activity.setWorldId(QWebEngineScript::ApplicationWorld);
    activity.setInjectionPoint(QWebEngineScript::DocumentCreation);
    activity.setRunsOnSubFrames(false);
    activity.setSourceCode(QStringLiteral("globalThis.__mokaidActivity = {dirty:false};"
        "for(const name of ['input','change','submit'])"
        "addEventListener(name,()=>{globalThis.__mokaidActivity.dirty=true},true);"));
    scripts_.append(activity);
    auto mime = mimeType().toUtf8();
    QByteArray page;
    if (kind() == "text") page = readableDocument(format_, content);
    else if (kind() == "video" || kind() == "audio") {
        const auto tag = kind().toUtf8();
        page = "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>"
            "<style>html,body{margin:0;width:100%;height:100%;background:#11131b;color:#eee;font-family:system-ui}body{display:grid;place-content:center}"
            "main{width:min(900px,90vw);text-align:center}video{max-width:100%;max-height:85vh}audio{width:min(540px,85vw)}p{font-size:14px;color:#a0a5b8}</style><main><"
            + tag + " controls preload=metadata src='/original'></" + tag + "><p>" + title_.toHtmlEscaped().toUtf8()
            + "</p><p id='media-error' hidden>This format needs a compatible player. Download the original to open it.</p></main>"
              "<script>document.querySelector('" + tag + "').addEventListener('error',()=>{document.getElementById('media-error').hidden=false})</script>";
    }
    profile_->setOffTheRecord(true);
    profile_->setHttpCacheType(QQuickWebEngineProfile::MemoryHttpCache);
    profile_->setHttpCacheMaximumSize(16 * 1024 * 1024);
    profile_->setPersistentCookiesPolicy(QQuickWebEngineProfile::NoPersistentCookies);
    profile_->setPersistentPermissionsPolicy(QQuickWebEngineProfile::PersistentPermissionsPolicy::StoreInMemory);
    profile_->setPushServiceEnabled(false);
    auto interceptor = std::make_unique<ResourceInterceptor>(policy_, profile_.get());
    profile_->setUrlRequestInterceptor(interceptor.release());
    auto scheme = std::make_unique<DocumentScheme>(policy_, std::move(content), std::move(mime), std::move(page), profile_.get());
    profile_->installUrlSchemeHandler("mokaid-preview", scheme.release());
}
PreviewController::PreviewController(ArtifactService& artifacts, QObject* parent)
    : QObject(parent), artifacts_(artifacts), thumbnailDirectory_(std::make_unique<QTemporaryDir>()) {}
PreviewController::~PreviewController() { nativePreview_.clear(); }
void PreviewController::registerScheme() {
    QWebEngineUrlScheme scheme("mokaid-preview");
    scheme.setSyntax(QWebEngineUrlScheme::Syntax::Host);
    scheme.setFlags(QWebEngineUrlScheme::SecureScheme);
    QWebEngineUrlScheme::registerScheme(scheme);
}
QVariantList PreviewController::documents() const {
    QVariantList list;
    for (const auto& document : documents_) list.append(QVariant::fromValue(document.get()));
    return list;
}
void PreviewController::openFile(const QVariantMap& file) {
    openCollection({file}, 0);
}
void PreviewController::openCollection(const QVariantList& files, int index) {
    if (index < 0 || index >= files.size()) return;
    collection_.clear();
    for (const auto& file : files) collection_.append(normalizeDeliverable(file.toMap()));
    collectionIndex_ = index;
    loadFile(collection_[index].toMap());
}
void PreviewController::previous() {
    if (loading_ || collectionIndex_ <= 0) return;
    --collectionIndex_; loadFile(collection_[collectionIndex_].toMap());
}
void PreviewController::next() {
    if (loading_ || collectionIndex_ + 1 >= collection_.size()) return;
    ++collectionIndex_; loadFile(collection_[collectionIndex_].toMap());
}
void PreviewController::loadFile(const QVariantMap& file) {
    const auto id = file.value("id").toString();
    const auto generation = ++generation_;
    failedFile_.clear(); visible_ = true;
    pending_.clear(); pendingBytes_.clear(); pendingIndex_ = -1;
    if (!validId(id)) { loading_ = false; failedFile_ = file; error_ = "Invalid deliverable identifier."; restoreCollectionSelection(); emit changed(); return; }
    if (file.value("size_bytes").toLongLong() > 32 * 1024 * 1024) {
        loading_ = false; failedFile_ = file; error_ = "This file exceeds the 32 MiB preview and download limit. It was not opened.";
        restoreCollectionSelection(); emit changed(); return;
    }
    for (int i = 0; i < 2; ++i) if (documents_[i] && files_[i].value("id").toString() == id
        && files_[i].value("version") == file.value("version") && files_[i].value("updated_at") == file.value("updated_at")) {
        loading_ = false; error_.clear(); activate(i); return;
    }
    loading_ = true; visible_ = true; error_.clear(); emit changed();
    artifacts_.fetch(id, this,
        [this, file, generation](ArtifactResult response) {
            if (generation != generation_) return;
            loading_ = false;
            if (!response.error.isEmpty()) { failedFile_ = file; error_ = response.error; restoreCollectionSelection(); emit changed(); return; }
            if (response.bytes.size() > 32 * 1024 * 1024) {
                failedFile_ = file; failedFile_.insert("size_bytes", response.bytes.size());
                error_ = "This file exceeds the 32 MiB preview limit. It was not opened."; restoreCollectionSelection(); emit changed(); return;
            }
            pending_ = file; pendingBytes_ = std::move(response.bytes);
            pendingIndex_ = !documents_[0] ? 0 : !documents_[1] ? 1 : 1 - active_;
            emit changed(); emit replacementRequested(pendingIndex_);
        });
}
void PreviewController::commitOpen() {
    if (pendingIndex_ < 0 || pending_.isEmpty()) return;
    nativePreview_.clear();
    active_ = pendingIndex_; documents_[active_].reset();
    files_[active_] = pending_;
    documents_[active_] = std::make_unique<PreviewDocument>(pending_, std::move(pendingBytes_));
    pending_.clear(); pendingIndex_ = -1; visible_ = true; emit changed();
}
void PreviewController::cancelOpen() {
    ++generation_; loading_ = false; pending_.clear(); pendingBytes_.clear(); pendingIndex_ = -1;
    restoreCollectionSelection();
    emit changed();
}
void PreviewController::restoreCollectionSelection() {
    if (documents_[active_]) {
        const auto id = files_[active_].value("id");
        for (int i = 0; i < collection_.size(); ++i) if (collection_[i].toMap().value("id") == id) { collectionIndex_ = i; return; }
        collection_ = {files_[active_]}; collectionIndex_ = 0;
    }
}
void PreviewController::activate(int index) {
    if (index < 0 || index > 1 || !documents_[index]) return;
    ++generation_; loading_ = false; pending_.clear(); pendingBytes_.clear(); pendingIndex_ = -1;
    nativePreview_.clear();
    active_ = index; restoreCollectionSelection(); visible_ = true; emit changed();
}
void PreviewController::setVisible(bool visible) {
    if (!visible) {
        nativePreview_.clear(); ++generation_; loading_ = false;
        pending_.clear(); pendingBytes_.clear(); pendingIndex_ = -1; restoreCollectionSelection();
    }
    visible_ = visible; emit changed();
}
QVariantMap PreviewController::describe(const QVariantMap& file) const { return describeDeliverable(file); }
void PreviewController::downloadCurrent() {
    if (documents_[active_]) emit downloadRequested(documents_[active_]->file());
    else if (collectionIndex_ >= 0 && collectionIndex_ < collection_.size()) {
        const auto file = collection_[collectionIndex_].toMap();
        if (validId(file.value("id").toString())) emit downloadRequested(file);
    }
}
void PreviewController::downloadFailed() {
    if (validId(failedFile_.value("id").toString()) && failedFile_.value("size_bytes").toLongLong() <= 32 * 1024 * 1024)
        emit downloadRequested(failedFile_);
}
void PreviewController::retryFailed() {
    if (validId(failedFile_.value("id").toString())) openFile(failedFile_);
}
void PreviewController::openNativePreview() {
    if (!documents_[active_] || loading_) return;
    if (!nativePreview_.open(documents_[active_]->localSource(), documents_[active_]->title())) {
        error_ = "A system preview is not available for this file. Download it to open in your preferred app."; emit changed();
    }
}
void PreviewController::openExternal(const QUrl& url) {
    if (url.scheme() == "https" && url.isValid() && url.userInfo().isEmpty()) QDesktopServices::openUrl(url);
}
void PreviewController::clear() {
    nativePreview_.clear();
    failedFile_.clear();
    ++thumbnailGeneration_; thumbnails_.clear(); thumbnailPending_.clear(); thumbnailUnavailable_.clear(); thumbnailQueue_.clear(); thumbnailActive_ = 0;
    thumbnailDirectory_ = std::make_unique<QTemporaryDir>(); thumbnailBytes_ = 0;
    ++thumbnailRevision_; emit thumbnailsChanged();
    ++generation_; loading_ = false; visible_ = false; cancelOpen();
    collection_.clear(); collectionIndex_ = 0;
    // The presentation destroys both views before acknowledging via commitClear in the next turn.
    emit clearViewsRequested();
}
QString PreviewController::thumbnailState(const QVariantMap& input) const {
    const auto file = normalizeDeliverable(input), format = describeDeliverable(file);
    const auto key = thumbnailKey(file);
    if (format.value("kind") != "image" || !validId(file.value("id").toString())) return "unavailable";
    if (thumbnails_.contains(key)) return "ready";
    if (thumbnailUnavailable_.contains(key)) return "unavailable";
    return thumbnailPending_.contains(key) ? "loading" : "idle";
}
QString PreviewController::thumbnailUrl(const QVariantMap& input) {
    const auto file = normalizeDeliverable(input);
    const auto key = thumbnailKey(file);
    if (thumbnails_.contains(key)) return thumbnails_.value(key);
    if (thumbnailState(file) != "idle") return {};
    thumbnailPending_.insert(key); thumbnailQueue_.append(file);
    QTimer::singleShot(0, this, [this] { fetchNextThumbnail(); });
    return {};
}
void PreviewController::fetchNextThumbnail() {
    if (thumbnailActive_ >= 3 || thumbnailQueue_.isEmpty()) return;
    const auto file = thumbnailQueue_.takeFirst();
    const auto key = thumbnailKey(file);
    const auto generation = thumbnailGeneration_;
    ++thumbnailActive_;
    auto finish = [this, key, generation](const QByteArray& png) {
        if (generation != thumbnailGeneration_) return;
        --thumbnailActive_; thumbnailPending_.remove(key);
        // Keep stable local URLs for the whole gallery. Evicting data URLs on
        // every revision would repeatedly redownload earlier visible images.
        // This private, session-scoped disk cache is bounded independently of
        // Qt Quick's decoded image cache, and disappears on workspace changes.
        bool saved = false;
        if (!png.isEmpty() && thumbnailDirectory_->isValid() && thumbnailBytes_ + png.size() <= 64 * 1024 * 1024) {
            const auto name = QString::fromLatin1(QCryptographicHash::hash(key.toUtf8(), QCryptographicHash::Sha256).toHex()) + ".png";
            QFile output(thumbnailDirectory_->filePath(name));
            if (output.open(QIODevice::WriteOnly)) {
                output.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
                saved = output.write(png) == png.size();
                if (saved) { thumbnails_.insert(key, QUrl::fromLocalFile(output.fileName()).toString()); thumbnailBytes_ += png.size(); }
            }
        }
        if (!saved) thumbnailUnavailable_.insert(key);
        ++thumbnailRevision_; emit thumbnailsChanged(); fetchNextThumbnail();
    };
    artifacts_.fetch(file.value("id").toString(), this, [this, generation, finish](ArtifactResult result) {
        if (generation != thumbnailGeneration_) return;
        if (!result.error.isEmpty()) { finish({}); return; }
        auto* watcher = new QFutureWatcher<QByteArray>(this);
        connect(watcher, &QFutureWatcher<QByteArray>::finished, this, [watcher, finish] { finish(watcher->result()); watcher->deleteLater(); });
        watcher->setFuture(QtConcurrent::run([bytes = std::move(result.bytes)] { return imageThumbnail(bytes); }));
    });
    if (thumbnailActive_ < 3) QTimer::singleShot(0, this, [this] { fetchNextThumbnail(); });
}
void PreviewController::commitClear() {
    for (auto& document : documents_) document.reset();
    files_ = {}; error_.clear(); emit changed();
}
}
