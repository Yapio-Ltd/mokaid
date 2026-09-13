#include <mokaid/network/api_client.hpp>
#include <QFile>
#include <QFileInfo>
#include <QHttpMultiPart>
#include <QJsonDocument>
#include <QJsonParseError>
#include <QMimeDatabase>
#include <QTimer>
#include <QCoreApplication>
#include <QFutureWatcher>
#include <QtConcurrentRun>
#include <memory>

namespace mokaid::desktop {
namespace {
struct DecodedBody { QJsonObject value; bool valid{true}; };
DecodedBody decodeJson(const QByteArray& bytes) {
    QJsonParseError problem;
    const auto document = QJsonDocument::fromJson(bytes, &problem);
    return {document.object(), problem.error == QJsonParseError::NoError && document.isObject()};
}
}
ApiClient::ApiClient(QUrl origin, QObject* parent) : QObject(parent), origin_(std::move(origin)), manager_(this) {
    const bool local = origin_.host() == "127.0.0.1" || origin_.host() == "localhost";
    if (!origin_.isValid() || origin_.host().isEmpty() || (origin_.scheme() != "https" && !(local && origin_.scheme() == "http"))
        || !origin_.userInfo().isEmpty() || origin_.hasQuery() || origin_.hasFragment()
        || !(origin_.path().isEmpty() || origin_.path() == "/"))
        qFatal("Invalid trusted Mokaid API origin");
    origin_.setPath({});
    manager_.setTransferTimeout(30000);
    decodePool_.setMaxThreadCount(2);
}
ApiClient::~ApiClient() { cancelAll(); }
void ApiClient::setSession(const QByteArray& token, const QString& user, bool admin) {
    if (context_.user_id != user.toStdString()) { cancelAll(); ++context_.generation; }
    token_ = token;
    context_.user_id = user.toStdString();
    context_.authenticated = !token.isEmpty();
    context_.platform_admin = admin;
}
void ApiClient::setWorkspace(const QString& workspace) {
    if (context_.workspace_id == workspace.toStdString()) return;
    cancelAll(); ++context_.generation;
    context_.workspace_id = workspace.toStdString();
}
void ApiClient::setOnline(bool online) {
    if (context_.online == online) return;
    context_.online = online;
    emit onlineChanged(online);
}
void ApiClient::reset() {
    cancelAll(); token_.fill('\0'); token_.clear();
    auto generation = context_.generation + 1;
    context_ = {}; context_.generation = generation;
}
void ApiClient::cancelAll() {
    auto pending = replies_;
    ++context_.generation;
    for (const auto& operation : operations_) operation->cancelled = true;
    operations_.clear();
    for (auto* reply : pending) reply->abort();
}
void ApiClient::cancelRequests(QObject* owner) {
    for (const auto& operation : operations_.values(owner)) operation->cancelled = true;
    operations_.remove(owner);
    const auto owners = owners_;
    for (auto it = owners.begin(); it != owners.end(); ++it)
        if (it.value() == owner) it.key()->abort();
}
QNetworkRequest ApiClient::makeRequest(const QString& path, core::Scope scope) const {
    QNetworkRequest request(origin_.resolved(QUrl(path)));
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::ManualRedirectPolicy);
    request.setRawHeader("Accept", "application/json");
    request.setRawHeader("User-Agent", "MokaidDesktop/" + QCoreApplication::applicationVersion().toUtf8());
    if (scope != core::Scope::public_api) request.setRawHeader("Authorization", "Bearer " + token_);
    if (scope == core::Scope::workspace) request.setRawHeader("x-workspace-id", QByteArray::fromStdString(context_.workspace_id));
    return request;
}
void ApiClient::request(const QByteArray& method, const QString& path, const QJsonObject& body,
                        core::Scope scope, QObject* owner, Completion done) {
    if (!core::isSafeApiPath(path.toStdString()) || !core::mayRequest(context_, scope, method != "GET")) {
        done({0, {}, {}, QStringLiteral("This action requires an active connection and the appropriate permissions."), false}); return;
    }
    auto req = makeRequest(path, scope);
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    QNetworkReply* reply = method == "GET" ? manager_.get(req)
        : manager_.sendCustomRequest(req, method, QJsonDocument(body).toJson(QJsonDocument::Compact));
    track(reply, scope, owner, std::move(done));
}
void ApiClient::upload(const QString& path, const QList<QUrl>& files, const QJsonObject& fields,
                       core::Scope scope, QObject* owner, Completion done) {
    if (!core::isSafeApiPath(path.toStdString()) || !core::mayRequest(context_, scope, true)) {
        done({0, {}, {}, "Upload unavailable while offline or without permission.", false}); return;
    }
    auto multi = std::make_unique<QHttpMultiPart>(QHttpMultiPart::FormDataType);
    for (auto it = fields.begin(); it != fields.end(); ++it) {
        if (it.key().contains('"') || it.key().contains('\r') || it.key().contains('\n')) continue;
        QHttpPart field;
        field.setHeader(QNetworkRequest::ContentDispositionHeader, "form-data; name=\"" + it.key() + "\"");
        field.setBody(it.value().toVariant().toString().toUtf8());
        multi->append(field);
    }
    for (const auto& url : files) {
        if (!url.isLocalFile()) { done({0, {}, {}, "Select a local file.", false}); return; }
        auto file = std::make_unique<QFile>(url.toLocalFile());
        if (!file->open(QIODevice::ReadOnly)) { done({0, {}, {}, file->errorString(), false}); return; }
        QString name = QFileInfo(file->fileName()).fileName(); name.replace('"', '_'); name.replace('\r', '_'); name.replace('\n', '_');
        QHttpPart part;
        const auto fieldName = path.endsWith("/drive/upload") || path.endsWith("/avatar") || path.endsWith("/logo") ? "file" : "files[]";
        part.setHeader(QNetworkRequest::ContentDispositionHeader, QString("form-data; name=\"%1\"; filename=\"%2\"").arg(fieldName, name));
        part.setHeader(QNetworkRequest::ContentTypeHeader, QMimeDatabase().mimeTypeForFile(file->fileName()).name());
        part.setBodyDevice(file.get()); file->setParent(multi.get()); file.release(); multi->append(part);
    }
    auto* reply = manager_.post(makeRequest(path, scope), multi.get());
    multi->setParent(reply); multi.release();
    track(reply, scope, owner, std::move(done));
}
void ApiClient::track(QNetworkReply* reply, core::Scope scope, QObject* owner, Completion done) {
    const auto cancellation = std::make_shared<Cancellation>();
    operations_.insert(owner, cancellation);
    replies_.insert(reply);
    owners_.insert(reply, owner);
    if (owner) connect(owner, &QObject::destroyed, reply, [reply] { reply->abort(); });
    const auto generation = context_.generation;
    QPointer<QObject> guard(owner);
    struct Transfer { QByteArray bytes; bool oversized{}; };
    auto transfer = std::make_shared<Transfer>();
    const qsizetype maximum = reply->url().path().endsWith("/raw") ? 32 * 1024 * 1024 : 8 * 1024 * 1024;
    reply->setReadBufferSize(256 * 1024);
    connect(reply, &QNetworkReply::readyRead, this, [reply, transfer, maximum] {
        auto chunk = reply->readAll();
        if (transfer->bytes.size() + chunk.size() > maximum) {
            transfer->oversized = true; transfer->bytes.clear(); reply->abort(); return;
        }
        transfer->bytes.append(chunk);
    });
    connect(reply, &QNetworkReply::finished, this, [this, reply, transfer, generation, guard, scope, cancellation, ownerKey = owner, done = std::move(done)]() mutable {
        replies_.remove(reply);
        owners_.remove(reply);
        const auto status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const bool cancelled = reply->error() == QNetworkReply::OperationCanceledError;
        const bool networkError = status == 0 && reply->error() != QNetworkReply::NoError && !cancelled;
        const bool jsonResponse = reply->header(QNetworkRequest::ContentTypeHeader).toString().contains("json", Qt::CaseInsensitive) && status != 204;
        reply->deleteLater();
        if (!guard || generation != context_.generation || cancellation->cancelled || (cancelled && !transfer->oversized)) {
            operations_.remove(ownerKey, cancellation); return;
        }
        if (transfer->oversized) { operations_.remove(ownerKey, cancellation); done({status, {}, {}, "The response exceeds the safe size limit. Use the browser to download large files.", false}); return; }
        if (networkError) setOnline(false); else if (status != 0) setOnline(true);
        auto finish = [this, transfer, guard, generation, status, networkError, scope, cancellation, ownerKey, done = std::move(done)](DecodedBody decoded) mutable {
            operations_.remove(ownerKey, cancellation);
            if (!guard || generation != context_.generation || cancellation->cancelled) return;
            auto json = std::move(decoded.value);
            QString error;
            if (status < 200 || status >= 300) {
                const auto problem = json.value("error");
                error = problem.isString() ? problem.toString() : problem.toObject().value("message").toString();
                if (error.isEmpty()) error = networkError ? "Unable to reach Mokaid. Your recent data remains available offline." : QString("Request failed (%1).").arg(status);
            } else if (!decoded.valid) error = "Mokaid returned an invalid JSON response. Please retry.";
            if (status == 401 && scope != core::Scope::public_api) emit sessionExpired();
            if (status == 403 && scope == core::Scope::administration) { context_.platform_admin = false; emit administratorDenied(); }
            done({status, std::move(json), std::move(transfer->bytes), std::move(error), networkError});
        };
        if (jsonResponse && transfer->bytes.size() > 256 * 1024) {
            auto watcher = std::make_unique<QFutureWatcher<DecodedBody>>(this);
            auto* observed = watcher.get();
            connect(observed, &QFutureWatcher<DecodedBody>::finished, this, [observed, finish = std::move(finish)]() mutable {
                const auto json = observed->result(); observed->deleteLater(); finish(json);
            });
            observed->setFuture(QtConcurrent::run(&decodePool_, [bytes = transfer->bytes] { return decodeJson(bytes); }));
            watcher.release(); // QObject parent owns the watcher until finished/cancelled.
        } else finish(jsonResponse ? decodeJson(transfer->bytes) : DecodedBody{});
    });
}
}
