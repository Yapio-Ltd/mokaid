#pragma once
#include <QUrl>
#include <QUrlQuery>
#include <QUuid>

namespace mokaid::desktop {
inline bool validBrowserOrigin(const QUrl& origin) {
    const bool loopback = origin.host() == "127.0.0.1" || origin.host() == "localhost" || origin.host() == "::1";
    return origin.isValid() && !origin.host().isEmpty()
        && (origin.scheme() == "https" || (origin.scheme() == "http" && loopback))
        && origin.userInfo().isEmpty() && !origin.hasQuery() && !origin.hasFragment()
        && (origin.path().isEmpty() || origin.path() == "/");
}
inline bool allowedAuthorizationUrl(const QUrl& origin, const QUrl& url) {
    const int defaultPort = origin.scheme() == "https" ? 443 : 80;
    if (!validBrowserOrigin(origin) || !url.isValid() || url.scheme() != origin.scheme()
        || url.host() != origin.host() || url.port(defaultPort) != origin.port(defaultPort)
        || !url.userInfo().isEmpty() || url.hasFragment()
        || url.path(QUrl::FullyEncoded) != "/desktop/authorize") return false;
    const auto items = QUrlQuery(url).queryItems(QUrl::FullyDecoded);
    if (items.size() != 1 || items.first().first != "request_id") return false;
    const auto id = items.first().second;
    return id.size() == 36 && !QUuid(id).isNull() && QUuid(id).toString(QUuid::WithoutBraces) == id.toLower();
}
inline bool allowedLoopbackRequest(const QByteArray& request, const QUrl& callback, const QString& state) {
    const auto headerEnd = request.indexOf("\r\n\r\n");
    if (headerEnd < 0 || request.size() > 8192 || request.size() != headerEnd + 4) return false;
    const auto lines = request.left(headerEnd).split('\n');
    if (lines.isEmpty() || state.isEmpty()) return false;
    const auto start = lines.first().trimmed().split(' ');
    if (start.size() != 3 || start[0] != "GET" || start[2] != "HTTP/1.1" || !start[1].startsWith("/callback?")) return false;
    QByteArray host; int hostCount = 0;
    for (const auto& line : lines)
        if (line.toLower().startsWith("host:")) { host = line.mid(5).trimmed(); ++hostCount; }
    if (hostCount != 1 || host != callback.authority().toUtf8()) return false;
    const QUrl target(QString::fromLatin1(start[1]), QUrl::StrictMode);
    const auto items = QUrlQuery(target).queryItems(QUrl::FullyDecoded);
    if (!target.isValid() || !target.isRelative() || !target.authority().isEmpty() || target.hasFragment()
        || target.path(QUrl::FullyEncoded) != "/callback" || items.size() != 2) return false;
    const QUrlQuery query(target);
    return query.queryItemValue("state", QUrl::FullyDecoded) == state
        && !query.queryItemValue("code", QUrl::FullyDecoded).isEmpty();
}
}
