#include "custom_avatar_loader.hpp"
#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDataStream>
#include <QFile>
#include <QTemporaryDir>
#include <QThreadPool>
#include <iostream>
#include <stdexcept>

namespace {
void expect(bool value, const char *message) { if (!value) throw std::runtime_error(message); }
void cachedAsset(const QString &directory, const QUrl &url, float height, bool valid = true) {
  const auto hash = QCryptographicHash::hash(url.toEncoded(), QCryptographicHash::Sha256).toHex();
  const auto path = directory + "/" + QString::fromLatin1(hash) + ".mokaidasset";
  QFile file(path); expect(file.open(QIODevice::WriteOnly), "Fixture cache opens");
  if (!valid) { file.write("corrupt revision"); return; }
  QDataStream stream(&file); stream.setByteOrder(QDataStream::LittleEndian);
  stream.setFloatingPointPrecision(QDataStream::SinglePrecision);
  stream.writeRawData("MOKASSET", 8); stream << quint32(4);
  stream << 0.F << 0.F << 0.F << 1.F << height << 1.F;
  // A valid empty scene isolates asynchronous decoding from renderer behavior.
  for (int count = 0; count < 6; ++count) stream << quint32(0);
}
void finishDecodes() {
  expect(QThreadPool::globalInstance()->waitForDone(5000), "Character decode completes within five seconds");
  QCoreApplication::sendPostedEvents();
  QCoreApplication::processEvents();
}
void revisions() {
  QTemporaryDir directory; expect(directory.isValid(), "Isolated character cache is available");
  mokaid::CustomAvatarLoader loader(nullptr, directory.path());
  const QUrl first("https://mokaid.com/api/avatar-assets/123/revision-one/model.mokaidasset");
  const QUrl second("https://mokaid.com/api/avatar-assets/123/revision-two/model.mokaidasset");
  const QUrl bad("https://mokaid.com/api/avatar-assets/123/corrupt/model.mokaidasset");
  cachedAsset(directory.path(), first, 1.75F); cachedAsset(directory.path(), second, 2.F);
  cachedAsset(directory.path(), bad, 0, false);
  QList<QUrl> ready, failed; float lastHeight = 0;
  QObject::connect(&loader, &mokaid::CustomAvatarLoader::ready,
      [&](const QString &key, const QUrl &url, std::shared_ptr<const mokaid::engine::Scene> scene) {
        expect(key == "custom:goku", "Ready keeps the stable asset identity");
        ready.append(url); lastHeight = scene->referenceHeight;
      });
  QObject::connect(&loader, &mokaid::CustomAvatarLoader::failed,
      [&](const QString &, const QUrl &url, const QString &) { failed.append(url); });

  loader.load("custom:goku", first); loader.load("custom:goku", first); finishDecodes();
  expect(ready == QList<QUrl>{first}, "Duplicate pending loads emit one ready event");
  ready.clear();
  loader.load("custom:goku", first); loader.load("custom:goku", second); finishDecodes();
  expect(ready == QList<QUrl>{second} && lastHeight == 2.F, "New URL replaces the same asset ID and suppresses the obsolete decode");
  ready.clear();
  loader.load("custom:goku", first); loader.load("custom:goku", second); loader.load("custom:goku", first); finishDecodes();
  expect(ready == QList<QUrl>{first}, "Returning to an earlier URL still suppresses both older request instances");
  ready.clear();
  loader.load("custom:goku", bad); loader.load("custom:goku", second); finishDecodes();
  expect(ready == QList<QUrl>{second} && failed.isEmpty(), "A superseded corrupt revision cannot report a current failure");
  ready.clear();
  loader.load("custom:goku", first); loader.reset(); finishDecodes();
  expect(ready.isEmpty() && failed.isEmpty(), "Workspace reset suppresses in-flight decoding");
  loader.load("custom:goku", bad); finishDecodes();
  expect(failed == QList<QUrl>{bad}, "Current failures identify their revision");
}
}
int main(int argc,char **argv) {
  QCoreApplication app(argc,argv);
  using mokaid::CustomAvatarLoader;
  const QUrl valid("https://mokaid.com/api/avatar-assets/123/opaque/model.mokaidasset");
  if(!CustomAvatarLoader::allowedUrl(valid)) return 1;
  for(const auto &value:{"http://mokaid.com/api/avatar-assets/123/token/model.mokaidasset",
      "https://evil.example/api/avatar-assets/123/token/model.mokaidasset",
      "https://mokaid.com.evil.example/api/avatar-assets/123/token/model.mokaidasset",
      "https://user:pass@mokaid.com/api/avatar-assets/123/token/model.mokaidasset",
      "file:///tmp/model.mokaidasset", "https://mokaid.com/api/agents/model.mokaidasset",
      "https://mokaid.com:8443/api/avatar-assets/123/token/model.mokaidasset"})
    if(CustomAvatarLoader::allowedUrl(QUrl(QString::fromLatin1(value)))) return 2;
  try {
    revisions();
    std::cout<<"Custom avatar origin restrictions and revision reloads passed\n";
  } catch (const std::exception &error) { std::cerr << error.what() << '\n'; return 3; }
}
