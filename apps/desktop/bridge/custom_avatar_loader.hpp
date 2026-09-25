#pragma once
#include <QObject>
#include <QNetworkAccessManager>
#include <QSet>
#include <QUrl>
#include <mokaid/engine/scene.hpp>

namespace mokaid {
// Downloads server-cooked assets without forwarding application credentials.
// Parsing and reference-pose calculation happen off the GUI/render threads.
class CustomAvatarLoader final : public QObject {
  Q_OBJECT
public:
  explicit CustomAvatarLoader(QObject *parent = nullptr);
  void load(const QString &key, const QUrl &url);
  static bool allowedUrl(const QUrl &url);
  void reset();
signals:
  void ready(QString key, std::shared_ptr<const engine::Scene> scene);
  void failed(QString message);
private:
  void decode(const QString &key, const QString &path, quint64 generation);
  QNetworkAccessManager network_;
  QSet<QString> pending_;
  quint64 generation_{};
};
}
