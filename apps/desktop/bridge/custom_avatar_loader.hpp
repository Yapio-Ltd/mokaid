#pragma once
#include <QObject>
#include <QHash>
#include <QNetworkAccessManager>
#include <QPointer>
#include <QUrl>
#include <mokaid/engine/scene.hpp>

namespace mokaid {
// Downloads server-cooked assets without forwarding application credentials.
// Parsing and reference-pose calculation happen off the GUI/render threads.
class CustomAvatarLoader final : public QObject {
  Q_OBJECT
public:
  explicit CustomAvatarLoader(QObject *parent = nullptr, const QString &cacheDirectory = {});
  void load(const QString &key, const QUrl &url);
  static bool allowedUrl(const QUrl &url);
  void reset();
signals:
  void ready(QString key, QUrl url, std::shared_ptr<const engine::Scene> scene);
  void failed(QString key, QUrl url, QString message);
private:
  struct Request {
    QUrl url;
    quint64 id{};
    QPointer<QNetworkReply> reply;
  };
  bool current(const QString &key, quint64 requestId) const;
  void decode(const QString &key, const QUrl &url, const QString &path, quint64 requestId);
  QNetworkAccessManager network_;
  QHash<QString, Request> pending_;
  QString cacheDirectory_;
  quint64 nextRequestId_{};
};
}
