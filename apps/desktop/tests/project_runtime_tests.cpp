#include <mokaid/presentation/project_runtime.hpp>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QStandardPaths>
#include <QTcpServer>
#include <QTemporaryDir>
#include <QtTest>
#ifdef Q_OS_UNIX
#include <cerrno>
#include <signal.h>
#endif

using namespace mokaid::desktop;

namespace {
bool writeFile(const QString& path, const QByteArray& contents) {
    QFile file(path);
    return file.open(QIODevice::WriteOnly) && file.write(contents) == contents.size();
}

QByteArray readFile(const QString& path) {
    QFile file(path);
    return file.open(QIODevice::ReadOnly) ? file.readAll() : QByteArray{};
}

bool createProject(const QString& folder, const QByteArray& body, bool dependencies = true,
                   const QString& postinstall = {}) {
    QJsonObject scripts{{"dev", "node server.cjs"}};
    if (!postinstall.isEmpty()) scripts.insert("postinstall", postinstall);
    const QJsonObject manifest{{"name", "runtime-test-project"}, {"version", "1.0.0"},
                               {"private", true}, {"scripts", scripts},
                               {"devDependencies", QJsonObject{{"vite", "file:./fixture-vite"}}}};
    if (!QDir().mkpath(folder + "/fixture-vite")) return false;
    if (dependencies && !QDir().mkpath(folder + "/node_modules")) return false;
    return writeFile(folder + "/package.json", QJsonDocument(manifest).toJson())
        && writeFile(folder + "/fixture-vite/package.json", R"({"name":"vite","version":"1.0.0"})")
        && writeFile(folder + "/.npmrc", "offline=true\nupdate-notifier=false\naudit=false\nfund=false\n")
        && writeFile(folder + "/server.cjs", body);
}

const QByteArray serverScript = R"JS(
const fs = require('node:fs');
const http = require('node:http');
fs.writeFileSync('launch.json', JSON.stringify({args: process.argv.slice(2),
    token: process.env.OPENAI_API_KEY, nodeOptions: process.env.NODE_OPTIONS,
    port: process.env.PORT, host: process.env.HOST}));
http.createServer((req, res) => res.end('runtime fixture')).listen(3000, '127.0.0.1', () => console.log('LISTENING'));
)JS";

class EnvironmentValue final {
public:
    EnvironmentValue(const char* key, const QByteArray& value)
        : key_(key), existed_(qEnvironmentVariableIsSet(key)), original_(qgetenv(key)) { qputenv(key, value); }
    ~EnvironmentValue() { if (existed_) qputenv(key_, original_); else qunsetenv(key_); }
private:
    const char* key_;
    bool existed_;
    QByteArray original_;
};
}

class ProjectRuntimeTests : public QObject {
    Q_OBJECT
private slots:
    void initTestCase() {
        if (QStandardPaths::findExecutable("node").isEmpty() || QStandardPaths::findExecutable("npm").isEmpty())
            QSKIP("These process integration tests require a local Node.js and npm installation.");
    }

    void init() {
        QTcpServer available;
        if (!available.listen(QHostAddress::LocalHost, 3000)) {
            if (available.serverError() == QAbstractSocket::AddressInUseError)
                QSKIP("Port 3000 already belongs to another application; leave it untouched.");
            QFAIL(qPrintable("Cannot reserve the test's loopback port: " + available.errorString()));
        }
    }

    void rejectsInvalidFoldersAndMissingDependencies() {
        ProjectRuntime runtime;
        runtime.inspect(QUrl("https://example.com/project"));
        QCOMPARE(runtime.state(), "error");
        QVERIFY(runtime.folder().isEmpty());
        QTemporaryDir folder;
        QVERIFY(folder.isValid());
        QVERIFY(createProject(folder.path(), serverScript, false));
        runtime.inspect(QUrl::fromLocalFile(folder.path()));
        QCOMPARE(runtime.state(), "ready");
        runtime.start(false);
        QCOMPARE(runtime.state(), "error");
        QVERIFY(runtime.error().contains("Dependencies are missing"));
        QVERIFY(!QFileInfo::exists(folder.path() + "/launch.json"));
        runtime.clear();
        QCOMPARE(runtime.state(), "empty");
        QVERIFY(runtime.error().isEmpty());
    }

    void occupiedPortNeverLaunchesTheProject() {
        QTemporaryDir folder;
        QVERIFY(createProject(folder.path(), serverScript));
        QTcpServer occupied;
        QVERIFY(occupied.listen(QHostAddress::LocalHost, 3000));
        ProjectRuntime runtime;
        runtime.inspect(QUrl::fromLocalFile(folder.path()));
        runtime.start(false);
        QCOMPARE(runtime.state(), "error");
        QVERIFY(runtime.error().contains("already in use"));
        QVERIFY(!QFileInfo::exists(folder.path() + "/launch.json"));
        QVERIFY(occupied.isListening());
    }

    void servesLocalhostWithRestrictedEnvironmentAndStopsDescendants() {
        QTemporaryDir folder;
        QVERIFY(folder.isValid());
        const QByteArray child = R"JS(
const {spawn} = require('node:child_process');
const child = spawn(process.execPath, ['-e', 'process.on("SIGTERM", () => {}); setInterval(() => {}, 1000)'], {stdio: 'ignore'});
fs.writeFileSync('child.pid', String(child.pid));
)JS";
        QVERIFY(createProject(folder.path(), serverScript + child));
        EnvironmentValue token("OPENAI_API_KEY", "test-provider-secret-must-not-be-inherited");
        EnvironmentValue nodeOptions("NODE_OPTIONS", "--invalid-injected-node-option");
        ProjectRuntime runtime;
        runtime.inspect(QUrl::fromLocalFile(folder.path()));
        runtime.start(false);
        QTRY_COMPARE_WITH_TIMEOUT(runtime.state(), "running", 10000);
        QCOMPARE(runtime.url(), QUrl("http://127.0.0.1:3000"));
        const auto launch = QJsonDocument::fromJson(readFile(folder.path() + "/launch.json")).object();
        QVERIFY(!launch.contains("token"));
        QVERIFY(!launch.contains("nodeOptions"));
        QCOMPARE(launch.value("port").toString(), "3000");
        QCOMPARE(launch.value("host").toString(), "127.0.0.1");
        QCOMPARE(launch.value("args").toArray(), QJsonArray({"--port", "3000", "--host", "127.0.0.1", "--strictPort"}));
#ifdef Q_OS_UNIX
        const auto childPid = readFile(folder.path() + "/child.pid").toLongLong();
        QVERIFY(childPid > 0);
#endif
        runtime.stop();
        QTRY_COMPARE_WITH_TIMEOUT(runtime.state(), "ready", 6000);
        QTcpServer available;
        QTRY_VERIFY_WITH_TIMEOUT(available.isListening() || available.listen(QHostAddress::LocalHost, 3000), 3000);
#ifdef Q_OS_UNIX
        QTRY_VERIFY_WITH_TIMEOUT(::kill(static_cast<pid_t>(childPid), 0) == -1 && errno == ESRCH, 3000);
#endif
        QVERIFY(runtime.url().isEmpty());
    }

    void streamingResponseIsReadyWithoutWaitingForBodyCompletion() {
        QTemporaryDir folder;
        QVERIFY(createProject(folder.path(), R"JS(
require('node:http').createServer((req, res) => {
    res.writeHead(200, {'Content-Type': 'text/html'});
    res.write('<html>ready');
    const timer = setInterval(() => res.write(' '), 50);
    res.on('close', () => clearInterval(timer));
}).listen(3000, '127.0.0.1');
)JS"));
        ProjectRuntime runtime;
        runtime.inspect(QUrl::fromLocalFile(folder.path()));
        runtime.start(false);
        QTRY_COMPARE_WITH_TIMEOUT(runtime.state(), "running", 5000);
        runtime.stop();
        QTRY_COMPARE_WITH_TIMEOUT(runtime.state(), "ready", 6000);
    }

    void cancellationDuringStartupDoesNotLeaveAServer() {
        QTemporaryDir folder;
        QVERIFY(createProject(folder.path(), serverScript));
        ProjectRuntime runtime;
        runtime.inspect(QUrl::fromLocalFile(folder.path()));
        for (int attempt = 0; attempt < 3; ++attempt) {
            runtime.start(false);
            runtime.stop();
            QTRY_COMPARE_WITH_TIMEOUT(runtime.state(), "ready", 6000);
        }
        QTest::qWait(200);
        QTcpServer available;
        QVERIFY(available.listen(QHostAddress::LocalHost, 3000));
    }

    void failedDevScriptReportsFailureAndCanBeRestarted() {
        QTemporaryDir folder;
        QVERIFY(createProject(folder.path(), "console.error('fixture startup failure'); process.exit(2);"));
        ProjectRuntime runtime;
        runtime.inspect(QUrl::fromLocalFile(folder.path()));
        runtime.start(false);
        QTRY_COMPARE_WITH_TIMEOUT(runtime.state(), "error", 5000);
        QVERIFY(runtime.output().contains("fixture startup failure"));
        QVERIFY(runtime.error().contains("server stopped"));
        QVERIFY(writeFile(folder.path() + "/server.cjs", serverScript));
        runtime.start(false);
        QTRY_COMPARE_WITH_TIMEOUT(runtime.state(), "running", 10000);
        QVERIFY(runtime.error().isEmpty());
        runtime.stop();
        QTRY_COMPARE_WITH_TIMEOUT(runtime.state(), "ready", 6000);
    }

    void pendingProbeCannotMakeARestartedProjectReady() {
        QTemporaryDir folder;
        QVERIFY(createProject(folder.path(), R"JS(
const fs = require('node:fs');
require('node:http').createServer(() => fs.writeFileSync('probe-received', '1')).listen(3000, '127.0.0.1');
)JS"));
        ProjectRuntime runtime;
        runtime.inspect(QUrl::fromLocalFile(folder.path()));
        runtime.start(false);
        QTRY_VERIFY_WITH_TIMEOUT(QFileInfo::exists(folder.path() + "/probe-received"), 10000);
        QCOMPARE(runtime.state(), "starting");
        runtime.stop();
        QTRY_COMPARE_WITH_TIMEOUT(runtime.state(), "ready", 6000);
        QVERIFY(writeFile(folder.path() + "/server.cjs", serverScript));
        runtime.start(false);
        QTRY_COMPARE_WITH_TIMEOUT(runtime.state(), "running", 10000);
        runtime.stop();
        QTRY_COMPARE_WITH_TIMEOUT(runtime.state(), "ready", 6000);
    }

    void localInstallStartsTheDevelopmentServer() {
        QTemporaryDir folder;
        QTemporaryDir home;
        QVERIFY(folder.isValid() && home.isValid());
        EnvironmentValue isolatedHome("HOME", home.path().toUtf8());
        EnvironmentValue isolatedUserProfile("USERPROFILE", home.path().toUtf8());
        QVERIFY(createProject(folder.path(), serverScript, false));
        ProjectRuntime runtime;
        runtime.inspect(QUrl::fromLocalFile(folder.path()));
        runtime.start(true);
        QTRY_COMPARE_WITH_TIMEOUT(runtime.state(), "running", 10000);
        QVERIFY(QFileInfo::exists(folder.path() + "/node_modules/vite/package.json"));
        QVERIFY(QFileInfo::exists(folder.path() + "/launch.json"));
        runtime.stop();
        QTRY_COMPARE_WITH_TIMEOUT(runtime.state(), "ready", 6000);
    }

    void cancelledLocalInstallDoesNotStartDevScript() {
        QTemporaryDir folder;
        QTemporaryDir home;
        QVERIFY(folder.isValid() && home.isValid());
        EnvironmentValue isolatedHome("HOME", home.path().toUtf8());
        EnvironmentValue isolatedUserProfile("USERPROFILE", home.path().toUtf8());
        QVERIFY(createProject(folder.path(), serverScript, false, "node postinstall.cjs"));
        QVERIFY(writeFile(folder.path() + "/postinstall.cjs", R"JS(
console.log('INSTALLING_FIXTURE');
setTimeout(() => process.exit(0), 30000);
)JS"));
        ProjectRuntime runtime;
        runtime.inspect(QUrl::fromLocalFile(folder.path()));
        runtime.start(true);
        QTRY_VERIFY_WITH_TIMEOUT(runtime.output().contains("INSTALLING_FIXTURE"), 10000);
        QCOMPARE(runtime.state(), "installing");
        runtime.clear();
        QTRY_COMPARE_WITH_TIMEOUT(runtime.state(), "empty", 6000);
        QVERIFY(runtime.folder().isEmpty());
        QVERIFY(runtime.error().isEmpty());
        QVERIFY(!QFileInfo::exists(folder.path() + "/launch.json"));
        QTcpServer available;
        QVERIFY(available.listen(QHostAddress::LocalHost, 3000));
    }

    void portClaimedDuringInstallationDoesNotLaunchTheProject() {
        QTemporaryDir folder;
        QTemporaryDir home;
        QVERIFY(folder.isValid() && home.isValid());
        EnvironmentValue isolatedHome("HOME", home.path().toUtf8());
        EnvironmentValue isolatedUserProfile("USERPROFILE", home.path().toUtf8());
        QVERIFY(createProject(folder.path(), serverScript, false, "node postinstall.cjs"));
        QVERIFY(writeFile(folder.path() + "/postinstall.cjs", R"JS(
console.log('INSTALLING_FIXTURE');
setTimeout(() => process.exit(0), 1000);
)JS"));
        ProjectRuntime runtime;
        runtime.inspect(QUrl::fromLocalFile(folder.path()));
        runtime.start(true);
        QTRY_VERIFY_WITH_TIMEOUT(runtime.output().contains("INSTALLING_FIXTURE"), 10000);
        QTcpServer otherApplication;
        QVERIFY(otherApplication.listen(QHostAddress::LocalHost, 3000));
        QTRY_COMPARE_WITH_TIMEOUT(runtime.state(), "error", 6000);
        QVERIFY(runtime.error().contains("already in use"));
        QVERIFY(!QFileInfo::exists(folder.path() + "/launch.json"));
        QVERIFY(otherApplication.isListening());
    }
};

QTEST_GUILESS_MAIN(ProjectRuntimeTests)
#include "project_runtime_tests.moc"
