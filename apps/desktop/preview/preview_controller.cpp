#include <mokaid/preview/preview_controller.hpp>
#include <QBuffer>
#include <QDesktopServices>
#include <QMimeDatabase>
#include <QRegularExpression>
#include <QTextDocument>
#include <QUuid>
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
        bool allowed = internal && (info.requestMethod() == "GET" || info.requestMethod() == "HEAD");
        if (info.requestMethod() == "GET") {
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
    DocumentScheme(PreviewResourcePolicy policy, QByteArray bytes, QByteArray mime, QObject* parent)
        : QWebEngineUrlSchemeHandler(parent), policy_(std::move(policy)), bytes_(std::move(bytes)), mime_(std::move(mime)) {}
    void requestStarted(QWebEngineUrlRequestJob* job) override {
        if (!policy_.internal(job->requestUrl()) || job->requestMethod() != "GET") {
            job->fail(QWebEngineUrlRequestJob::RequestDenied); return;
        }
        if (job->requestUrl().path() != "/index.html") {
            job->fail(QWebEngineUrlRequestJob::UrlNotFound); return;
        }
        job->setAdditionalResponseHeaders({{"Content-Security-Policy", policy_.csp()},
            {"X-Content-Type-Options", "nosniff"}, {"Referrer-Policy", "no-referrer"},
            {"Cache-Control", "no-store"}, {"Permissions-Policy", "camera=(), microphone=(), geolocation=(), usb=(), payment=()"}});
        auto buffer = std::make_unique<QBuffer>();
        buffer->setData(bytes_); buffer->open(QIODevice::ReadOnly);
        buffer->setParent(job); job->reply(mime_, buffer.release());
    }
private:
    const PreviewResourcePolicy policy_;
    const QByteArray bytes_, mime_;
};
}
PreviewDocument::PreviewDocument(const QVariantMap& file, QByteArray content)
    : title_(file.value("name").toString()), version_(file.value("version").toString()),
      profile_(std::make_unique<QQuickWebEngineProfile>()) {
    policy_.host = QUuid::createUuid().toString(QUuid::WithoutBraces);
    url_ = QUrl("mokaid-preview://" + policy_.host + "/index.html");
    QWebEngineScript activity;
    activity.setName("Mokaid isolated activity tracker");
    activity.setWorldId(QWebEngineScript::ApplicationWorld);
    activity.setInjectionPoint(QWebEngineScript::DocumentCreation);
    activity.setRunsOnSubFrames(false);
    activity.setSourceCode(QStringLiteral("globalThis.__mokaidActivity = {dirty:false};"
        "for(const name of ['input','change','submit','pointerdown','keydown'])"
        "addEventListener(name,()=>{globalThis.__mokaidActivity.dirty=true},true);"));
    scripts_.append(activity);
    auto mime = file.value("mime_type").toString().toUtf8();
    if (mime.isEmpty()) mime = QMimeDatabase().mimeTypeForFile(title_, QMimeDatabase::MatchExtension).name().toUtf8();
    if (title_.endsWith(".html", Qt::CaseInsensitive) || title_.endsWith(".htm", Qt::CaseInsensitive)) mime = "text/html";
    if (mime == "text/markdown" || title_.endsWith(".md", Qt::CaseInsensitive)) {
        QTextDocument document; document.setMarkdown(QString::fromUtf8(content));
        content = document.toHtml().toUtf8(); mime = "text/html";
    } else if (mime.startsWith("text/") && mime != "text/html") {
        content = "<!doctype html><meta charset=utf-8><pre style='white-space:pre-wrap;padding:24px'>"
            + QString::fromUtf8(content).toHtmlEscaped().toUtf8() + "</pre>"; mime = "text/html";
    }
    profile_->setOffTheRecord(true);
    profile_->setHttpCacheType(QQuickWebEngineProfile::MemoryHttpCache);
    profile_->setHttpCacheMaximumSize(16 * 1024 * 1024);
    profile_->setPersistentCookiesPolicy(QQuickWebEngineProfile::NoPersistentCookies);
    profile_->setPersistentPermissionsPolicy(QQuickWebEngineProfile::PersistentPermissionsPolicy::StoreInMemory);
    profile_->setPushServiceEnabled(false);
    auto interceptor = std::make_unique<ResourceInterceptor>(policy_, profile_.get());
    profile_->setUrlRequestInterceptor(interceptor.release());
    auto scheme = std::make_unique<DocumentScheme>(policy_, std::move(content), std::move(mime), profile_.get());
    profile_->installUrlSchemeHandler("mokaid-preview", scheme.release());
}
PreviewController::PreviewController(ArtifactService& artifacts, QObject* parent) : QObject(parent), artifacts_(artifacts) {}
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
    static const QRegularExpression idPattern("^[0-9a-fA-F-]{36}$");
    const auto id = file.value("id").toString();
    if (!idPattern.match(id).hasMatch()) { error_ = "Invalid deliverable identifier."; emit changed(); return; }
    for (int i = 0; i < 2; ++i) if (documents_[i] && files_[i].value("id").toString() == id) { activate(i); return; }
    const auto generation = ++generation_;
    loading_ = true; visible_ = true; error_.clear(); emit changed();
    artifacts_.fetch(id, this,
        [this, file, generation](ArtifactResult response) {
            if (generation != generation_) return;
            loading_ = false;
            if (!response.error.isEmpty()) { error_ = response.error; emit changed(); return; }
            if (response.bytes.size() > 32 * 1024 * 1024) { error_ = "This file exceeds the 32 MiB preview limit. It was not opened."; emit changed(); return; }
            pending_ = file; pendingBytes_ = std::move(response.bytes);
            pendingIndex_ = !documents_[0] ? 0 : !documents_[1] ? 1 : 1 - active_;
            emit changed(); emit replacementRequested(pendingIndex_);
        });
}
void PreviewController::commitOpen() {
    if (pendingIndex_ < 0 || pending_.isEmpty()) return;
    active_ = pendingIndex_; documents_[active_].reset();
    files_[active_] = pending_;
    documents_[active_] = std::make_unique<PreviewDocument>(pending_, std::move(pendingBytes_));
    pending_.clear(); pendingIndex_ = -1; visible_ = true; emit changed();
}
void PreviewController::cancelOpen() { pending_.clear(); pendingBytes_.clear(); pendingIndex_ = -1; emit changed(); }
void PreviewController::activate(int index) {
    if (index < 0 || index > 1 || !documents_[index]) return;
    active_ = index; visible_ = true; emit changed();
}
void PreviewController::setVisible(bool visible) { visible_ = visible; emit changed(); }
void PreviewController::openExternal(const QUrl& url) {
    if (url.scheme() == "https" && url.isValid() && url.userInfo().isEmpty()) QDesktopServices::openUrl(url);
}
void PreviewController::clear() {
    ++generation_; loading_ = false; visible_ = false; cancelOpen();
    // The presentation destroys both views before acknowledging via commitClear in the next turn.
    emit clearViewsRequested();
}
void PreviewController::commitClear() {
    for (auto& document : documents_) document.reset();
    files_ = {}; error_.clear(); emit changed();
}
}
