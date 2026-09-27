#include "custom_avatar_loader.hpp"
#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFutureWatcher>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QSaveFile>
#include <QStandardPaths>
#include <QtConcurrent>

namespace mokaid {
namespace {
constexpr qint64 maxBytes = 128LL * 1024 * 1024;
using Decoded = std::pair<std::shared_ptr<const engine::Scene>, QString>;
}
CustomAvatarLoader::CustomAvatarLoader(QObject *parent, const QString &cacheDirectory)
    : QObject(parent), network_(this), cacheDirectory_(cacheDirectory) {}
bool CustomAvatarLoader::allowedUrl(const QUrl &url) {
  const QUrl origin(QStringLiteral(MOKAID_API_ORIGIN));
  return url.isValid() && url.scheme() == origin.scheme() && url.host() == origin.host() &&
         url.port(-1) == origin.port(-1) && url.userInfo().isEmpty() && url.fragment().isEmpty() &&
         url.path().startsWith("/api/avatar-assets/") && url.path().endsWith("/model.mokaidasset");
}
void CustomAvatarLoader::reset() {
  pending_.clear();
  const auto replies = network_.findChildren<QNetworkReply *>();
  for (auto *reply : replies) reply->abort();
}
bool CustomAvatarLoader::current(const QString &key, quint64 requestId) const {
  const auto request = pending_.constFind(key);
  return request != pending_.cend() && request->id == requestId;
}
void CustomAvatarLoader::load(const QString &key, const QUrl &url) {
  if (const auto prior = pending_.constFind(key); prior != pending_.cend()) {
    if (prior->url == url) return;
    const auto reply = prior->reply;
    pending_.remove(key);
    if (reply) reply->abort();
  }
  if (!allowedUrl(url)) { emit failed(key, url, "This custom character has an invalid download address."); return; }
  const auto requestId = ++nextRequestId_;
  pending_.insert(key, {url, requestId, {}});
  const auto directory = cacheDirectory_.isEmpty()
      ? QStandardPaths::writableLocation(QStandardPaths::CacheLocation) + "/characters" : cacheDirectory_;
  QDir().mkpath(directory);
  const auto hash = QCryptographicHash::hash(url.toEncoded(), QCryptographicHash::Sha256).toHex();
  const auto path = directory + "/" + QString::fromLatin1(hash) + ".mokaidasset";
  if (QFile::exists(path)) { decode(key, url, path, requestId); return; }
  QNetworkRequest request(url);
  request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::SameOriginRedirectPolicy);
  request.setTransferTimeout(60000);
  auto *reply = network_.get(request);
  pending_[key].reply = reply;
  auto bytes = std::make_shared<QByteArray>();
  connect(reply, &QNetworkReply::readyRead, this, [reply, bytes] {
    if (reply->bytesAvailable() + bytes->size() > maxBytes) { reply->abort(); return; }
    bytes->append(reply->readAll());
  });
  connect(reply, &QNetworkReply::downloadProgress, this, [reply](qint64 received, qint64 total) {
    if (received > maxBytes || total > maxBytes) reply->abort();
  });
  connect(reply, &QNetworkReply::finished, this, [this, reply, bytes, key, url, path, requestId] {
    reply->deleteLater();
    if (!current(key, requestId)) return;
    const auto code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    if (reply->error() != QNetworkReply::NoError || code != 200 ||
        bytes->size() + reply->bytesAvailable() > maxBytes) {
      pending_.remove(key); emit failed(key, url, "The custom character could not load. Check your connection and retry."); return;
    }
    bytes->append(reply->readAll());
    if (!bytes->startsWith("MOKASSET")) {
      pending_.remove(key); emit failed(key, url, "The downloaded character is invalid. Please retry."); return;
    }
    QSaveFile file(path);
    if (!file.open(QIODevice::WriteOnly) || file.write(*bytes) != bytes->size() || !file.commit()) {
      pending_.remove(key); emit failed(key, url, "There is not enough storage to save this character."); return;
    }
    decode(key, url, path, requestId);
  });
}
void CustomAvatarLoader::decode(const QString &key, const QUrl &url, const QString &path, quint64 requestId) {
  auto *watcher = new QFutureWatcher<Decoded>(this);
  connect(watcher, &QFutureWatcher<Decoded>::finished, this, [this, watcher, key, url, path, requestId] {
    auto [scene, error] = watcher->result(); watcher->deleteLater();
    if (!current(key, requestId)) return;
    pending_.remove(key);
    if (!scene) { QFile::remove(path); emit failed(key, url, error); return; }
    emit ready(key, url, std::move(scene));
  });
  watcher->setFuture(QtConcurrent::run([path]() -> Decoded {
    try { return {engine::loadScene(path.toStdString()), {}}; }
    catch (const std::exception &) { return {{}, "This character could not be read. Please retry the download."}; }
  }));
}
}
