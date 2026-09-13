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
};
QTEST_GUILESS_MAIN(ResourcePolicyTest)
#include "resource_policy_tests.moc"
