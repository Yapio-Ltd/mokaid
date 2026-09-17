#include <mokaid/preview/resource_policy.hpp>
#include <QtTest>
class ResourcePolicyTest : public QObject {
    Q_OBJECT
private slots:
    void origins() {
        mokaid::desktop::PreviewResourcePolicy policy; policy.host = "isolated-document";
        QVERIFY(policy.internal(QUrl("mokaid-preview://isolated-document/index.html#section")));
        QVERIFY(!policy.internal(QUrl("mokaid-preview://another-document/index.html")));
        QVERIFY(!policy.internal(QUrl("file:///etc/passwd")));
        QVERIFY(!policy.remote(QUrl("https://127.0.0.1"), policy.scriptHosts));
        QVERIFY(!policy.remote(QUrl("https://mokaid.com/api/me"), policy.scriptHosts));
        QVERIFY(!policy.remote(QUrl("https://cdn.jsdelivr.net.attacker.example/a.js"), policy.scriptHosts));
        QVERIFY(!policy.remote(QUrl("https://token@cdn.jsdelivr.net/a.js"), policy.scriptHosts));
        QVERIFY(policy.remote(QUrl("https://cdn.jsdelivr.net/npm/library/a.js"), policy.scriptHosts));
        QVERIFY(policy.csp().contains("connect-src 'none'"));
        QVERIFY(policy.csp().contains("form-action 'none'"));
    }
    void builtInPdfResourcesAreLimitedToPdfProfiles() {
        mokaid::desktop::PreviewResourcePolicy policy;
        const QUrl viewer("chrome-extension://mhjfbmdgcfjbbpaeojofohoefgiehjai/index.html");
        const QUrl resource("chrome://resources/js/assert.js");
        QVERIFY(!policy.pdfViewer(viewer)); QVERIFY(!policy.pdfResource(resource));
        QVERIFY(policy.csp().contains("object-src 'none'"));
        policy.pdfDocument = true;
        QVERIFY(policy.pdfViewer(viewer)); QVERIFY(policy.pdfResource(resource));
        QVERIFY(!policy.internal(viewer)); // Never treated as an owned document-scheme response.
        QVERIFY(!policy.pdfViewer(resource)); // Resource origins cannot become navigation targets.
        QVERIFY(!policy.pdfViewer(QUrl("chrome-extension://other-extension/index.html")));
        QVERIFY(!policy.pdfResource(QUrl("chrome://settings/")));
        QVERIFY(!policy.pdfResource(QUrl("chrome://version/")));
        QVERIFY(!policy.pdfResource(QUrl("chrome-extension://user@mhjfbmdgcfjbbpaeojofohoefgiehjai/index.html")));
        QVERIFY(!policy.pdfResource(QUrl("chrome-extension://mhjfbmdgcfjbbpaeojofohoefgiehjai:443/index.html")));
        QVERIFY(!policy.pdfResource(QUrl("https://mhjfbmdgcfjbbpaeojofohoefgiehjai/index.html")));
        QVERIFY(policy.csp().contains("frame-src chrome-extension://mhjfbmdgcfjbbpaeojofohoefgiehjai"));
        QVERIFY(policy.csp().contains("default-src 'none'"));
    }
};
QTEST_GUILESS_MAIN(ResourcePolicyTest)
#include "resource_policy_tests.moc"
