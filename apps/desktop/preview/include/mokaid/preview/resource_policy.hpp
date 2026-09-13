#pragma once
#include <QUrl>
#include <QStringList>

namespace mokaid::desktop {
// Immutable policy shared with Chromium's request interception thread. No application credentials.
struct PreviewResourcePolicy {
    QString host;
    QStringList scriptHosts{"cdn.jsdelivr.net", "cdnjs.cloudflare.com", "unpkg.com"};
    QStringList styleHosts{"fonts.googleapis.com", "cdn.jsdelivr.net", "cdnjs.cloudflare.com"};
    QStringList imageHosts{"images.unsplash.com", "images.pexels.com"};
    QStringList fontHosts{"fonts.gstatic.com", "cdn.jsdelivr.net", "cdnjs.cloudflare.com"};
    bool internal(const QUrl& url) const {
        return url.scheme() == "mokaid-preview" && url.host() == host
            && url.userInfo().isEmpty() && url.port() == -1
            && !url.path().contains("..") && !url.path().contains('\\');
    }
    bool remote(const QUrl& url, const QStringList& hosts) const {
        return url.scheme() == "https" && url.userInfo().isEmpty()
            && (url.port() == -1 || url.port() == 443) && hosts.contains(url.host());
    }
    QByteArray csp() const {
        const auto origins = [](const QStringList& hosts) {
            QByteArray result;
            for (const auto& domain : hosts) result += " https://" + domain.toUtf8();
            return result;
        };
        return "default-src 'none'; script-src 'self' 'unsafe-inline'" + origins(scriptHosts)
            + "; style-src 'self' 'unsafe-inline'" + origins(styleHosts)
            + "; img-src 'self' data: blob:" + origins(imageHosts)
            + "; font-src 'self' data:" + origins(fontHosts)
            + "; media-src 'self' blob:; connect-src 'none'; frame-src 'none'; object-src 'none';"
              " base-uri 'none'; form-action 'none'; worker-src 'none'; frame-ancestors 'none';";
    }
};
}
