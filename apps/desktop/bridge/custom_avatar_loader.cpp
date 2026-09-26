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
CustomAvatarLoader::CustomAvatarLoader(QObject *parent) : QObject(parent), network_(this) {}
bool CustomAvatarLoader::allowedUrl(const QUrl &url) {
  const QUrl origin(QStringLiteral(MOKAID_API_ORIGIN));
  return url.isValid() && url.scheme() == origin.scheme() && url.host() == origin.host() &&
         url.port(-1) == origin.port(-1) && url.userInfo().isEmpty() && url.fragment().isEmpty() &&
         url.path().startsWith("/api/avatar-assets/") && url.path().endsWith("/model.mokaidasset");
}
void CustomAvatarLoader::reset() {
  ++generation_; pending_.clear();
  const auto replies = network_.findChildren<QNetworkReply *>();
  for (auto *reply : replies) reply->abort();
}
void CustomAvatarLoader::load(const QString &key, const QUrl &url) {
  if (pending_.contains(key)) return;
  if (!allowedUrl(url)) { emit failed("This custom character has an invalid download address."); return; }
  pending_.insert(key);
  const auto generation = generation_;
  const auto directory = QStandardPaths::writableLocation(QStandardPaths::CacheLocation) + "/characters";
  QDir().mkpath(directory);
  const auto hash = QCryptographicHash::hash(url.toEncoded(), QCryptographicHash::Sha256).toHex();
  const auto path = directory + "/" + QString::fromLatin1(hash) + ".mokaidasset";
  if (QFile::exists(path)) { decode(key, path, generation); return; }
  QNetworkRequest request(url);
  request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::SameOriginRedirectPolicy);
  request.setTransferTimeout(60000);
  auto *reply = network_.get(request);
  auto bytes = std::make_shared<QByteArray>();
  connect(reply, &QNetworkReply::readyRead, this, [reply, bytes] {
    if (reply->bytesAvailable() + bytes->size() > maxBytes) { reply->abort(); return; }
    bytes->append(reply->readAll());
  });
  connect(reply, &QNetworkReply::downloadProgress, this, [reply](qint64 received, qint64 total) {
    if (received > maxBytes || total > maxBytes) reply->abort();
  });
  connect(reply, &QNetworkReply::finished, this, [this, reply, bytes, key, path, generation] {
    reply->deleteLater();
    if (generation != generation_) return;
    const auto code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    if (reply->error() != QNetworkReply::NoError || code != 200 ||
        bytes->size() + reply->bytesAvailable() > maxBytes) {
      pending_.remove(key); emit failed("The custom character could not load. Check your connection and retry."); return;
    }
    bytes->append(reply->readAll());
    if (!bytes->startsWith("MOKASSET")) {
      pending_.remove(key); emit failed("The downloaded character is invalid. Please retry."); return;
    }
    QSaveFile file(path);
    if (!file.open(QIODevice::WriteOnly) || file.write(*bytes) != bytes->size() || !file.commit()) {
      pending_.remove(key); emit failed("There is not enough storage to save this character."); return;
    }
    decode(key, path, generation);
  });
}
void CustomAvatarLoader::decode(const QString &key, const QString &path, quint64 generation) {
  auto *watcher = new QFutureWatcher<Decoded>(this);
  connect(watcher, &QFutureWatcher<Decoded>::finished, this, [this, watcher, key, path, generation] {
    auto [scene, error] = watcher->result(); watcher->deleteLater();
    if (generation != generation_) return;
    pending_.remove(key);
    if (!scene) { QFile::remove(path); emit failed(error); return; }
    emit ready(key, std::move(scene));
  });
  watcher->setFuture(QtConcurrent::run([path]() -> Decoded {
    try { return {engine::loadScene(path.toStdString()), {}}; }
    catch (const std::exception &) { return {{}, "This character could not be read. Please retry the download."}; }
  }));
}
}
