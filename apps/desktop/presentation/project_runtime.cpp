#include <mokaid/presentation/project_runtime.hpp>
#include <QDesktopServices>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkReply>
#include <QNetworkProxy>
#include <QProcessEnvironment>
#include <QStandardPaths>
#include <QTcpServer>
#ifdef Q_OS_UNIX
#include <cerrno>
#include <signal.h>
#include <unistd.h>
#endif
#ifdef Q_OS_WIN
#include <windows.h>
#include <tlhelp32.h>
#endif

namespace mokaid::desktop {
ProjectRuntime::ProjectRuntime(QObject* parent) : QObject(parent) {
    process_.setProcessChannelMode(QProcess::MergedChannels);
    network_.setProxy(QNetworkProxy::NoProxy);
#ifdef Q_OS_UNIX
    process_.setChildProcessModifier([this] {
        if (::setpgid(0, 0) != 0) process_.failChildProcessModifier("create project process group", errno);
    });
#endif
    connect(&process_, &QProcess::started, this, [this] {
        processGroup_ = process_.processId();
        if (stopping_) { stopTree(false); process_.terminate(); }
    });
    connect(&process_, &QProcess::readyReadStandardOutput, this, [this] { appendOutput(process_.readAllStandardOutput()); });
    connect(&process_, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart) {
            deadline_.stop(); probeTimer_.stop(); killTimer_.stop(); cancelProbe(); processGroup_ = 0;
            if (stopping_) {
                stopping_ = false; state_ = folder_.isEmpty() ? "empty" : failed_ ? "error" : "ready"; emit changed();
            } else fail("Node could not start. Check your Node.js installation and project folder.");
        }
    });
    connect(&process_, &QProcess::finished, this, [this](int code, QProcess::ExitStatus status) {
        appendOutput(process_.readAllStandardOutput());
        ++generation_; deadline_.stop(); probeTimer_.stop(); cancelProbe();
        const auto previous = state_;
        // npm may leave descendants behind when its parent exits.
        stopTree(true); killTimer_.stop(); processGroup_ = 0;
        if (stopping_) { stopping_ = false; state_ = failed_ ? "error" : (folder_.isEmpty() ? "empty" : "ready"); }
        else if (previous == "installing" && code == 0 && status == QProcess::NormalExit) { launchDev(); return; }
        else if (failed_) state_ = "error";
        else fail(previous == "installing" ? "Dependency installation failed. Review the output and retry." : "The development server stopped. Review the output before restarting.");
        emit changed();
    });
    probeTimer_.setInterval(700); connect(&probeTimer_, &QTimer::timeout, this, &ProjectRuntime::probe);
    deadline_.setSingleShot(true); connect(&deadline_, &QTimer::timeout, this, [this] {
        error_ = state_ == "installing" ? "Dependency installation timed out." : "The server did not become ready on port 3000 within 90 seconds.";
        failed_ = true; stop();
    });
    killTimer_.setSingleShot(true); killTimer_.setInterval(2500);
    connect(&killTimer_, &QTimer::timeout, this, [this] { stopTree(true); process_.kill(); });
}
ProjectRuntime::~ProjectRuntime() {
    ++generation_; cancelProbe();
    disconnect(&process_, nullptr, this, nullptr);
    stopTree(true);
    if (process_.state() != QProcess::NotRunning) { process_.kill(); process_.waitForFinished(1000); }
}
void ProjectRuntime::fail(const QString& message) { error_ = message; state_ = "error"; emit changed(); }
void ProjectRuntime::appendOutput(const QByteArray& bytes) {
    output_ += QString::fromUtf8(bytes);
    if (output_.size() > 64000) output_ = output_.right(64000);
    emit changed();
}
void ProjectRuntime::inspect(const QUrl& url) {
    if (busy()) return;
    ++generation_; cancelProbe(); failed_ = false; stopping_ = false;
    folder_.clear(); name_.clear(); error_.clear(); output_.clear(); framework_.clear();
    if (!url.isLocalFile() || !url.host().isEmpty()) { fail("Choose a local project folder."); return; }
    const auto path = QFileInfo(url.toLocalFile()).canonicalFilePath();
    QFile package(QDir(path).filePath("package.json"));
    if (path.isEmpty() || !QFileInfo(path).isDir() || !package.open(QIODevice::ReadOnly) || package.size() > 1024 * 1024) { fail("Choose the extracted project folder containing package.json."); return; }
    QJsonParseError parse;
    const auto manifest = QJsonDocument::fromJson(package.readAll(), &parse).object();
    const auto deps = manifest.value("dependencies").toObject(), dev = manifest.value("devDependencies").toObject();
    if (parse.error != QJsonParseError::NoError || manifest.value("scripts").toObject().value("dev").toString().isEmpty()) { fail("This project needs a valid package.json with a dev script."); return; }
    framework_ = deps.contains("next") || dev.contains("next") ? "next" : deps.contains("vite") || dev.contains("vite") ? "vite" : "";
    if (framework_.isEmpty()) { fail("Local preview currently supports Next.js and Vite projects. Use the project’s README for other runtimes."); return; }
    folder_ = path; name_ = manifest.value("name").toString(QFileInfo(path).fileName()); state_ = "ready"; emit changed();
}
void ProjectRuntime::start(bool installDependencies) {
    if (busy() || folder_.isEmpty()) return;
    auto paths = QProcessEnvironment::systemEnvironment().value("PATH").split(QDir::listSeparator(), Qt::SkipEmptyParts);
#ifdef Q_OS_MACOS
    paths << "/opt/homebrew/bin" << "/usr/local/bin";
#endif
    node_ = QStandardPaths::findExecutable("node", paths);
    if (node_.isEmpty()) { fail("Install Node.js with npm, then reopen the project. Node.js was not found."); return; }
    const QDir nodeDir(QFileInfo(node_).canonicalPath());
    QStringList npmCandidates{nodeDir.filePath("node_modules/npm/bin/npm-cli.js"), nodeDir.filePath("../lib/node_modules/npm/bin/npm-cli.js")};
    const auto npmExecutable = QStandardPaths::findExecutable("npm", paths);
    if (!npmExecutable.isEmpty()) npmCandidates.prepend(QFileInfo(npmExecutable).canonicalFilePath());
    npm_.clear();
    for (const auto& candidate : npmCandidates) if (candidate.endsWith(".js") && QFileInfo(candidate).isFile()) { npm_ = QFileInfo(candidate).canonicalFilePath(); break; }
    if (npm_.isEmpty()) { fail("npm could not be located beside Node.js. Reinstall Node.js with npm."); return; }
    if (!checkPort()) return;
    error_.clear(); output_.clear(); failed_ = false; stopping_ = false; ++generation_;
    // Do not give generated code the desktop's API tokens or provider credentials.
    const auto source = QProcessEnvironment::systemEnvironment(); QProcessEnvironment environment;
    for (const auto& key : {"HOME", "USERPROFILE", "TMPDIR", "TEMP", "TMP", "SystemRoot", "SYSTEMROOT", "APPDATA", "LOCALAPPDATA", "COMSPEC", "LANG"})
        if (source.contains(key)) environment.insert(key, source.value(key));
    environment.insert("PATH", paths.join(QDir::listSeparator())); environment.insert("PORT", "3000");
    environment.insert("HOST", "127.0.0.1"); environment.insert("NEXT_TELEMETRY_DISABLED", "1"); environment.insert("BROWSER", "none");
    process_.setProcessEnvironment(environment); process_.setWorkingDirectory(folder_);
    if (installDependencies) {
        state_ = "installing"; deadline_.start(300000);
        execute({npm_, QFileInfo::exists(folder_ + "/package-lock.json") ? "ci" : "install", "--no-audit", "--no-fund"});
    } else if (!QFileInfo(folder_ + "/node_modules").isDir()) fail("Dependencies are missing. Select Install dependencies before starting.");
    else launchDev();
}
void ProjectRuntime::execute(const QStringList& args) { process_.start(node_, args); emit changed(); }
bool ProjectRuntime::checkPort() {
    QTcpServer portCheck;
    if (portCheck.listen(QHostAddress::LocalHost, 3000)) return true;
    fail("Port 3000 is already in use or unavailable. Stop that server before starting this project.");
    return false;
}
void ProjectRuntime::launchDev() {
    // Installation may take minutes; do not probe another app that claimed the port meanwhile.
    if (!checkPort()) return;
    state_ = "starting";
    QStringList args{npm_, "run", "dev", "--", "--port", "3000"};
    if (framework_ == "next") args << "--hostname" << "127.0.0.1";
    else args << "--host" << "127.0.0.1" << "--strictPort";
    deadline_.start(90000); probeTimer_.start(); execute(args);
}
void ProjectRuntime::probe() {
    if (probeReply_ || state_ != "starting" || process_.state() != QProcess::Running) return;
    const auto generation = generation_;
    QNetworkRequest request(QUrl("http://127.0.0.1:3000/")); request.setTransferTimeout(1500);
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::ManualRedirectPolicy);
    auto* reply = network_.get(request);
    probeReply_ = reply;
    reply->setReadBufferSize(4096);
    // HTTP headers establish readiness even when the app streams its response.
    // Abort after the headers so a preview probe cannot accumulate response data.
    connect(reply, &QNetworkReply::metaDataChanged, this, [this, reply, generation] {
        if (generation != generation_ || state_ != "starting") return;
        const auto status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (status >= 200 && status < 400) { state_ = "running"; deadline_.stop(); probeTimer_.stop(); emit changed(); }
        if (status >= 200) reply->abort();
    });
    connect(reply, &QNetworkReply::finished, this, [this, reply, generation] {
        if (probeReply_ == reply) probeReply_.clear();
        reply->deleteLater();
        if (generation != generation_ || state_ != "starting") return;
        const auto status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (status >= 200 && status < 400) { state_ = "running"; deadline_.stop(); probeTimer_.stop(); emit changed(); }
    });
}
void ProjectRuntime::cancelProbe() {
    if (!probeReply_) return;
    auto* reply = probeReply_.data(); probeReply_.clear();
    reply->abort(); reply->deleteLater();
}
void ProjectRuntime::stopTree(bool force) {
    if (processGroup_ <= 0) return;
#ifdef Q_OS_UNIX
    ::kill(-static_cast<pid_t>(processGroup_), force ? SIGKILL : SIGTERM);
#elif defined(Q_OS_WIN)
    // Walk descendants before terminating npm so node's server does not survive it.
    QList<DWORD> pids{static_cast<DWORD>(processGroup_)};
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot != INVALID_HANDLE_VALUE) {
        PROCESSENTRY32 entry{}; entry.dwSize = sizeof(entry);
        for (qsizetype i = 0; i < pids.size(); ++i) {
            if (Process32First(snapshot, &entry)) do { if (entry.th32ParentProcessID == pids[i] && !pids.contains(entry.th32ProcessID)) pids.append(entry.th32ProcessID); } while (Process32Next(snapshot, &entry));
        }
        CloseHandle(snapshot);
    }
    for (auto it = pids.crbegin(); it != pids.crend(); ++it) { HANDLE child = OpenProcess(PROCESS_TERMINATE, FALSE, *it); if (child) { TerminateProcess(child, 0); CloseHandle(child); } }
    Q_UNUSED(force);
#else
    Q_UNUSED(force);
#endif
}
void ProjectRuntime::stop() {
    ++generation_; deadline_.stop(); probeTimer_.stop(); cancelProbe();
    if (process_.state() == QProcess::NotRunning) {
        stopTree(true); processGroup_ = 0; killTimer_.stop(); stopping_ = false;
        state_ = folder_.isEmpty() ? "empty" : failed_ ? "error" : "ready"; emit changed(); return;
    }
    stopping_ = true; state_ = "stopping";
    // A Starting child may still be between fork and exec. The started handler
    // terminates it as soon as its process group and executable are established.
    if (process_.state() == QProcess::Running) { stopTree(false); process_.terminate(); }
    killTimer_.start(); emit changed();
}
void ProjectRuntime::openBrowser() { if (state_ == "running") QDesktopServices::openUrl(url()); }
void ProjectRuntime::clear() {
    stop(); folder_.clear(); name_.clear(); output_.clear(); error_.clear(); framework_.clear(); failed_ = false;
    if (!busy()) state_ = "empty"; emit changed();
}
}
