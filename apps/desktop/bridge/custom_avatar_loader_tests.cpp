#include "custom_avatar_loader.hpp"
#include <QCoreApplication>
#include <iostream>
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
  std::cout<<"Custom avatar origin restrictions passed\n";
}
