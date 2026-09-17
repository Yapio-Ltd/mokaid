#include <mokaid/application/authorization_policy.hpp>
#include <QtTest>
using namespace mokaid::desktop;
class AuthorizationPolicyTests final : public QObject {
    Q_OBJECT
private slots:
    void onlyExplicitOrigins() {
        QVERIFY(validBrowserOrigin(QUrl("https://mokaid.com")));
        QVERIFY(validBrowserOrigin(QUrl("http://localhost:5173")));
        QVERIFY(!validBrowserOrigin(QUrl("http://mokaid.com")));
        QVERIFY(!validBrowserOrigin(QUrl("https://mokaid.com/redirect")));
        QVERIFY(!validBrowserOrigin(QUrl("https://user@mokaid.com")));
        QVERIFY(!validBrowserOrigin(QUrl("https://mokaid.com?token=secret")));
    }
    void onlyAuthorizationTransactions() {
        const QUrl origin("https://mokaid.com");
        const QString query("?request_id=ababcabc-0000-4000-8000-000000000001");
        QVERIFY(allowedAuthorizationUrl(origin, QUrl("https://mokaid.com/desktop/authorize" + query)));
        QVERIFY(allowedAuthorizationUrl(origin, QUrl("https://mokaid.com:443/desktop/authorize" + query)));
        for (const auto& prefix : {"https://evil.invalid/desktop/authorize", "https://mokaid.com:8443/desktop/authorize",
                 "http://mokaid.com/desktop/authorize", "https://mokaid.com/redirect", "https://user@mokaid.com/desktop/authorize",
                 "https://mokaid.com/desktop%2fauthorize", "https://mokaid.com/desktop/authorize/"})
            QVERIFY2(!allowedAuthorizationUrl(origin, QUrl(QString::fromLatin1(prefix) + query)), prefix);
        QVERIFY(!allowedAuthorizationUrl(origin, QUrl("https://mokaid.com/desktop/authorize" + query + "&redirect_uri=https://evil.invalid")));
        QVERIFY(!allowedAuthorizationUrl(origin, QUrl("https://mokaid.com/desktop/authorize" + query + "#fragment")));
        QVERIFY(!allowedAuthorizationUrl(origin, QUrl("https://mokaid.com/desktop/authorize?request_id=not-a-uuid")));
        QVERIFY(!allowedAuthorizationUrl(QUrl("http://localhost:4000"), QUrl("http://localhost:5173/desktop/authorize" + query)));
        QVERIFY(allowedAuthorizationUrl(QUrl("http://localhost:5173"), QUrl("http://localhost:5173/desktop/authorize" + query)));
    }
    void loopbackChecksHostPathAndTransaction() {
        const QUrl callback("http://127.0.0.1:54321/callback");
        const QByteArray valid("GET /callback?code=one-time-code&state=transaction HTTP/1.1\r\nHost: 127.0.0.1:54321\r\n\r\n");
        QVERIFY(allowedLoopbackRequest(valid, callback, "transaction"));
        QVERIFY(!allowedLoopbackRequest(valid, callback, "different"));
        for (const auto& broken : {
                 QByteArray(valid).replace("127.0.0.1:54321", "evil.invalid"),
                 QByteArray(valid).replace("127.0.0.1:54321", "127.0.0.1:54322"),
                 QByteArray(valid).replace("Host:", "X-Host:"),
                 QByteArray(valid).replace("\r\n\r\n", "\r\nHost: 127.0.0.1:54321\r\n\r\n"),
                 QByteArray(valid).replace("/callback?", "http://evil.invalid/callback?"),
                 QByteArray(valid).replace("/callback?", "//evil.invalid/callback?"),
                 QByteArray(valid).replace("/callback?", "/%63allback?"),
                 QByteArray(valid).replace("/callback?", "/callback%?"),
                 QByteArray(valid).replace("/callback?", "/other?"),
                 QByteArray(valid).replace("code=one-time-code", "code="),
                 QByteArray(valid).replace("state=transaction", "state=transaction&state=second"),
                 QByteArray(valid).replace("\r\n\r\n", ""),
                 QByteArray(valid).append("unexpected body")})
            QVERIFY(!allowedLoopbackRequest(broken, callback, "transaction"));
    }
};
QTEST_GUILESS_MAIN(AuthorizationPolicyTests)
#include "authorization_policy_tests.moc"
