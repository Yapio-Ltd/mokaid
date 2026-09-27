#include <mokaid/features/mail_center_controller.hpp>
#include <QFile>
#include <QJsonDocument>
#include <QPointer>
#include <QSignalSpy>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QUrlQuery>
#include <QtTest>
#include <algorithm>
#include <functional>
#include <memory>

using namespace mokaid::desktop;

namespace {
// Exercises the actual HTTP client against an isolated loopback fixture only.
class MailApi final : public QObject {
public:
    QTcpServer server;
    QStringList paths, methods;
    QList<QJsonObject> bodies;
    std::function<void(QTcpSocket*, const QString&)> handler;
    MailApi() {
        server.listen(QHostAddress::LocalHost, 0);
        connect(&server, &QTcpServer::newConnection, this, [this] {
            while (server.hasPendingConnections()) {
                auto* socket = server.nextPendingConnection();
                connect(socket, &QTcpSocket::disconnected, socket, &QObject::deleteLater);
                connect(socket, &QTcpSocket::readyRead, this, [this, socket] {
                    const auto bytes = socket->property("request").toByteArray() + socket->readAll();
                    socket->setProperty("request", bytes);
                    const auto end = bytes.indexOf("\r\n\r\n");
                    if (end < 0 || socket->property("handled").toBool()) return;
                    qsizetype size = 0;
                    for (const auto& line : bytes.left(end).split('\n'))
                        if (line.toLower().startsWith("content-length:")) size = line.mid(15).trimmed().toLongLong();
                    if (bytes.size() < end + 4 + size) return;
                    socket->setProperty("handled", true);
                    paths.append(QString::fromUtf8(bytes.split(' ').value(1)));
                    methods.append(QString::fromUtf8(bytes.split(' ').value(0)));
                    bodies.append(QJsonDocument::fromJson(bytes.mid(end + 4, size)).object());
                    if (handler) handler(socket, paths.last());
                });
            }
        });
    }
    QUrl origin() const { return QUrl(QString("http://127.0.0.1:%1").arg(server.serverPort())); }
    static void reply(QTcpSocket* socket, const QJsonObject& body, int status = 200) {
        const auto bytes = QJsonDocument(body).toJson(QJsonDocument::Compact);
        socket->write("HTTP/1.1 " + QByteArray::number(status) + " Response\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: " + QByteArray::number(bytes.size()) + "\r\n\r\n" + bytes);
        socket->disconnectFromHost();
    }
    static void error(QTcpSocket* socket, int status) {
        reply(socket, {{"error", QJsonObject{{"code", "denied"}, {"message", "Fixture refusal"}}}}, status);
    }
    int count(const QString& path) const { return paths.count(path); }
};

struct MailFixture {
    MailApi remote;
    ApiClient api{remote.origin()};
    PhoenixClient realtime;
    SessionController session{api, realtime};
    std::unique_ptr<MailAccountsController> accounts;
    std::unique_ptr<DriveDownload> download;
    std::unique_ptr<MailCenterController> mail;
    bool sendAllowed{true}, manageAllowed{false};
    QJsonArray rows;
    bool more{};
    QJsonObject detail{{"id", "message-a"}, {"mail_account_id", "mail-a"}, {"from_email", "original@example.test"},
                       {"subject", "Original subject"}, {"body_text", "Original body"}, {"is_read", true}};
    std::function<bool(QTcpSocket*, const QString&)> intercept;
    MailFixture() {
        api.setSession("test-token", "test-user", false);
        api.setWorkspace("workspace-a");
        accounts = std::make_unique<MailAccountsController>(api, session);
        download = std::make_unique<DriveDownload>(api);
        mail = std::make_unique<MailCenterController>(api, session, *accounts, *download);
        remote.handler = [this](QTcpSocket* socket, const QString& path) {
            if (intercept && intercept(socket, path)) return;
            if (path == "/api/mail/accounts") {
                MailApi::reply(socket, {{"data", QJsonArray{
                    QJsonObject{{"id", "mail-a"}, {"email_address", "a@example.test"}, {"status", "active"}, {"provider", "gmail"}},
                    QJsonObject{{"id", "mail-b"}, {"email_address", "b@example.test"}, {"status", "active"}, {"provider", "imap"}}}},
                    {"meta", QJsonObject{{"can_send", sendAllowed}, {"can_manage", manageAllowed}}}});
            } else if (path.startsWith("/api/mail/messages?")) {
                MailApi::reply(socket, {{"data", rows}, {"meta", QJsonObject{{"has_more", more}, {"total", 120}}}});
            } else if (path.startsWith("/api/mail/folders")) {
                MailApi::reply(socket, {{"data", QJsonArray{QJsonObject{{"key", "inbox"}, {"count", 120}, {"unread_count", 7}}}},
                    {"meta", QJsonObject{{"labels", QJsonArray{QJsonObject{{"name", "Client"}, {"count", 12}}}}}}});
            } else if (path.startsWith("/api/mail/messages/")) {
                MailApi::reply(socket, {{"data", detail}});
            } else MailApi::reply(socket, {{"data", QJsonArray{}}});
        };
    }
    void draft() {
        mail->compose();
        mail->setDraft("to", "to@example.test");
        mail->setDraft("subject", "Draft subject");
        mail->setDraft("body_text", "Draft body");
    }
    QJsonObject lastSubmission() const {
        const auto index = remote.paths.lastIndexOf("/api/mail/send");
        return index < 0 ? QJsonObject{} : remote.bodies.at(index);
    }
};
}

class MailCenterTests final : public QObject {
    Q_OBJECT
private slots:
    void htmlIsRebuiltWithoutActiveContentOrResources() {
        const auto safe = MailCenterController::safeBody(
            "<h1>Hello</h1><b>Bold</b><img src='https://tracker.example/pixel' onerror='bad()'>"
            "<iframe src='file:///private/file'></iframe><script>bad()</script>"
            "<a href='javascript:bad()'>Unsafe link</a><a href='https://example.test/path'>Good link</a>"
            "<div style='background-image:url(https://tracker.example/css)'>Text</div>", "fallback");
        QVERIFY(safe.contains("Hello"));
        QVERIFY(safe.contains("<b>Bold</b>"));
        QVERIFY(safe.contains("Good link"));
        for (const auto* blocked : {"<script", "<iframe", "<img", "src=", "onerror", "javascript:", "tracker.example", "file:///", "background-image"})
            QVERIFY2(!safe.contains(blocked, Qt::CaseInsensitive), qPrintable(safe));
        const auto plain = MailCenterController::safeBody({}, "<b>Literal</b>\nNext");
        QVERIFY(plain.contains("&lt;b&gt;Literal&lt;/b&gt;"));
        QVERIFY(plain.contains("<br>"));
    }

    void externalLinksRequireExplicitSafeSchemes() {
        MailFixture f;
        QSignalSpy links(f.mail.get(), &MailCenterController::requestExternal);
        for (const auto* url : {"javascript:alert(1)", "file:///etc/passwd", "data:text/html,x", "https://user:pw@example.test", "mailto:me@example.test?body=hidden"}) {
            f.mail->openLink(QUrl(url));
        }
        QCOMPARE(links.count(), 0);
        f.mail->openLink(QUrl("https://example.test/path"));
        f.mail->openLink(QUrl("mailto:me@example.test"));
        QCOMPARE(links.count(), 2);
    }

    void permissionsAndOfflineStatePreventSubmission() {
        MailFixture f;
        QVERIFY(f.remote.server.isListening());
        f.sendAllowed = false;
        f.accounts->refresh();
        QTRY_COMPARE(f.accounts->accounts().size(), 2);
        QVERIFY(!f.mail->canSend());
        f.draft(); f.mail->send();
        QCOMPARE(f.remote.count("/api/mail/send"), 0);
        QVERIFY(!f.mail->deliveryUncertain());
        f.sendAllowed = true; f.accounts->refresh();
        QTRY_VERIFY(f.mail->canSend());
        f.api.setOnline(false);
        QVERIFY(!f.mail->canSend());
        f.mail->send();
        QCOMPARE(f.remote.count("/api/mail/send"), 0);
        QVERIFY(!f.mail->deliveryUncertain());
    }

    void foldersFilteringAndPaginationUseServerResponses() {
        MailFixture f;
        f.accounts->refresh(); QTRY_COMPARE(f.accounts->accounts().size(), 2);
        f.accounts->select("mail-b");
        f.mail->compose(); // Keep the fixture from selecting a detail automatically.
        f.rows = QJsonArray{QJsonObject{{"id", "server-message"}, {"subject", "Server row"}}}; f.more = true;
        f.mail->setFolder("sent");
        QTRY_COMPARE(f.mail->messages().size(), 1);
        QTRY_COMPARE(f.mail->folders().size(), 1);
        QCOMPARE(f.mail->folders().first().toMap().value("count").toInt(), 120);
        QVERIFY(f.mail->hasMore());
        f.mail->setFilter("unread"); f.mail->setSort("sender"); f.mail->search("invoice & tax");
        QTRY_VERIFY(!f.mail->busy());
        QTRY_VERIFY(std::any_of(f.remote.paths.begin(), f.remote.paths.end(), [](const QString& path) {
            const QUrlQuery query(QUrl("http://fixture" + path));
            return query.queryItemValue("q") == "invoice & tax" && query.queryItemValue("filter") == "unread" && query.queryItemValue("sort") == "sender";
        }));
        QTRY_VERIFY(!f.mail->busy());
        f.rows = QJsonArray{QJsonObject{{"id", "next-message"}, {"subject", "Next page"}}}; f.more = false;
        f.mail->loadMore(); QTRY_COMPARE(f.mail->messages().size(), 2);
        QVERIFY(!f.mail->hasMore());
        const auto path = f.remote.paths.last(); const QUrlQuery query(QUrl("http://fixture" + path));
        QCOMPARE(query.queryItemValue("account_id"), QString("mail-b"));
        QCOMPARE(query.queryItemValue("folder"), QString("sent"));
        QCOMPARE(query.queryItemValue("offset"), QString("1"));
        QCOMPARE(f.mail->messages().last().toMap().value("id").toString(), QString("next-message"));
    }

    void changingTheViewedMailboxDoesNotChangeAnExistingDraftSender() {
        MailFixture f;
        f.accounts->refresh(); QTRY_COMPARE(f.accounts->accounts().size(), 2);
        f.accounts->select("mail-a"); f.draft();
        f.accounts->select("mail-b");
        QCOMPARE(f.mail->draft().value("account_id").toString(), QString("mail-a"));
        f.mail->setDraft("from", "forged@example.test");
        QVERIFY(!f.mail->draft().contains("from"));
        f.intercept = [&](QTcpSocket* socket, const QString& path) {
            if (path != "/api/mail/send") return false;
            const auto request = f.remote.bodies.last();
            MailApi::reply(socket, {{"data", QJsonObject{{"id", "outbox-a"}, {"request_id", request.value("request_id")}, {"status", "sent"}}}});
            return true;
        };
        f.mail->send(); QTRY_VERIFY(!f.mail->sending());
        QCOMPARE(f.lastSubmission().value("account_id").toString(), QString("mail-a"));
        QVERIFY(!f.lastSubmission().contains("from"));
        QVERIFY(!f.mail->hasDraft());
    }

    void ambiguousDeliveryThenForbiddenKeepsTheSameRequestAndDraftLocked() {
        MailFixture f;
        f.accounts->refresh(); QTRY_COMPARE(f.accounts->accounts().size(), 2);
        int attempt = 0;
        f.intercept = [&](QTcpSocket* socket, const QString& path) {
            if (path != "/api/mail/send") return false;
            ++attempt;
            if (attempt == 1) {
                // Provider acceptance is possible, but the HTTP result was truncated.
                socket->write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 1000\r\nConnection: close\r\n\r\n{}");
                socket->disconnectFromHost();
            } else if (attempt == 2) MailApi::error(socket, 403);
            else {
                const auto request = f.remote.bodies.last();
                MailApi::reply(socket, {{"data", QJsonObject{{"id", "outbox-a"}, {"request_id", request.value("request_id")}, {"status", "sent"}}}});
            }
            return true;
        };
        f.draft(); f.mail->send(); QTRY_VERIFY(!f.mail->sending());
        QCOMPARE(attempt, 1); QVERIFY(f.mail->deliveryUncertain());
        const auto original = f.lastSubmission();
        f.api.setOnline(true); f.mail->checkDelivery(); QTRY_COMPARE(attempt, 2); QTRY_VERIFY(!f.mail->sending());
        QVERIFY(f.mail->deliveryUncertain());
        f.mail->setDraft("body_text", "Changed while uncertain"); f.mail->discardDraft();
        QCOMPARE(f.mail->draft().value("body_text").toString(), QString("Draft body"));
        QVERIFY(f.mail->hasDraft());
        f.mail->checkDelivery(); QTRY_COMPARE(attempt, 3); QTRY_VERIFY(!f.mail->sending());
        QCOMPARE(f.remote.bodies.at(f.remote.paths.indexOf("/api/mail/send")), original);
        QCOMPARE(f.lastSubmission(), original);
        QVERIFY(!f.mail->deliveryUncertain()); QVERIFY(!f.mail->hasDraft());
    }

    void firstValidationRejectionPreservesAnEditableDraftAndAllowsANewRequest() {
        MailFixture f;
        f.accounts->refresh(); QTRY_COMPARE(f.accounts->accounts().size(), 2);
        int posted = 0;
        f.intercept = [&](QTcpSocket* socket, const QString& path) {
            if (path != "/api/mail/send") return false;
            ++posted;
            if (posted == 1) MailApi::error(socket, 422);
            else {
                const auto request = f.remote.bodies.last();
                MailApi::reply(socket, {{"data", QJsonObject{{"id", "outbox-corrected"}, {"request_id", request.value("request_id")}, {"status", "sent"}}}});
            }
            return true;
        };
        f.draft(); f.mail->send(); QTRY_COMPARE(posted, 1); QTRY_VERIFY(!f.mail->sending());
        const auto rejected = f.lastSubmission();
        QVERIFY(!rejected.value("request_id").toString().isEmpty());
        QVERIFY(!f.mail->deliveryUncertain()); QVERIFY(f.mail->hasDraft());
        QCOMPARE(f.mail->draft().value("subject").toString(), QString("Draft subject"));
        QCOMPARE(f.mail->draft().value("body_text").toString(), QString("Draft body"));
        f.mail->setDraft("body_text", "Corrected after validation rejection");
        QCOMPARE(f.mail->draft().value("body_text").toString(), QString("Corrected after validation rejection"));
        f.mail->send(); QTRY_COMPARE(posted, 2); QTRY_VERIFY(!f.mail->sending());
        QVERIFY(f.lastSubmission().value("request_id") != rejected.value("request_id"));
        QCOMPARE(f.lastSubmission().value("body_text").toString(), QString("Corrected after validation rejection"));
        QVERIFY(!f.mail->deliveryUncertain()); QVERIFY(!f.mail->hasDraft());
    }

    void knownOutboxIsPolledWithGetAndDefiniteFailureAllowsANewRequest() {
        MailFixture f;
        f.accounts->refresh(); QTRY_COMPARE(f.accounts->accounts().size(), 2);
        QString firstId; int posted = 0; bool failed = false;
        f.intercept = [&](QTcpSocket* socket, const QString& path) {
            if (path == "/api/mail/send") {
                ++posted; const auto request = f.remote.bodies.last();
                if (firstId.isEmpty()) firstId = request.value("request_id").toString();
                MailApi::reply(socket, {{"data", QJsonObject{{"id", "outbox-a"}, {"request_id", request.value("request_id")}, {"status", "unknown"}}}});
                return true;
            }
            if (path == "/api/mail/outbox/outbox-a") {
                MailApi::reply(socket, {{"data", QJsonObject{{"id", "outbox-a"}, {"request_id", firstId}, {"status", failed ? "failed" : "unknown"}}}});
                return true;
            }
            return false;
        };
        f.draft(); f.mail->send(); QTRY_VERIFY(!f.mail->sending()); QVERIFY(f.mail->deliveryUncertain());
        f.mail->checkDelivery(); QTRY_VERIFY(f.remote.paths.contains("/api/mail/outbox/outbox-a")); QTRY_VERIFY(!f.mail->sending());
        QCOMPARE(f.remote.methods.at(f.remote.paths.indexOf("/api/mail/outbox/outbox-a")), QString("GET"));
        QCOMPARE(posted, 1); QVERIFY(f.mail->deliveryUncertain());
        failed = true; f.mail->checkDelivery(); QTRY_VERIFY(!f.mail->deliveryUncertain());
        QVERIFY(f.mail->hasDraft());
        f.mail->setDraft("body_text", "Edited after definite failure"); f.mail->send(); QTRY_COMPARE(posted, 2); QTRY_VERIFY(!f.mail->sending());
        QVERIFY(f.lastSubmission().value("request_id").toString() != firstId);
        QCOMPARE(f.lastSubmission().value("body_text").toString(), QString("Edited after definite failure"));
    }

    void attachmentsAreBoundedAndOnlySelectedMessageAttachmentsCanOpen() {
        MailFixture f;
        f.accounts->refresh(); QTRY_COMPARE(f.accounts->accounts().size(), 2);
        QTemporaryDir directory; QVERIFY(directory.isValid());
        const auto smallPath = directory.filePath("note.txt");
        { QFile file(smallPath); QVERIFY(file.open(QIODevice::WriteOnly)); QCOMPARE(file.write("Attachment data"), qint64(15)); }
        const auto bigPath = directory.filePath("large.bin");
        { QFile file(bigPath); QVERIFY(file.open(QIODevice::WriteOnly)); QVERIFY(file.resize(5 * 1024 * 1024 + 1)); }
        f.draft(); f.mail->addAttachments({QUrl::fromLocalFile(smallPath)});
        QCOMPARE(f.mail->draftAttachments().size(), 1);
        f.mail->addAttachments({QUrl::fromLocalFile(bigPath)});
        QCOMPARE(f.mail->draftAttachments().size(), 1); QVERIFY(!f.mail->error().isEmpty());
        for (int index = 0; index < 9; ++index) f.mail->addAttachments({QUrl::fromLocalFile(smallPath)});
        QCOMPARE(f.mail->draftAttachments().size(), 10);
        f.mail->addAttachments({QUrl::fromLocalFile(smallPath)}); QCOMPARE(f.mail->draftAttachments().size(), 10);
        f.detail.insert("attachments", QJsonArray{QJsonObject{{"id", "part-a"}, {"filename", "note.txt"}, {"mime_type", "text/plain"}, {"size", 15}}});
        f.mail->select("message-a"); QTRY_VERIFY(!f.mail->detailLoading());
        QSignalSpy preview(f.mail.get(), &MailCenterController::openAttachment);
        f.mail->attachment("not-in-message", true); f.mail->attachment("../other", true); QCOMPARE(preview.count(), 0);
        f.mail->attachment("part-a", true); QCOMPARE(preview.count(), 1);
        const auto file = preview.first().first().toMap();
        QCOMPARE(file.value("mail_message_id").toString(), QString("message-a"));
        QCOMPARE(file.value("mail_attachment_id").toString(), QString("part-a"));
        const QString attachmentPath = "/api/mail/messages/message-a/attachments/part-a";
        const QByteArray attachmentBytes("Attachment data");
        f.intercept = [&](QTcpSocket* socket, const QString& path) {
            if (path != attachmentPath) return false;
            socket->write("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nConnection: close\r\nContent-Length: "
                + QByteArray::number(attachmentBytes.size()) + "\r\n\r\n" + attachmentBytes);
            socket->disconnectFromHost();
            return true;
        };
        QSignalSpy saveRequested(f.download.get(), &DriveDownload::saveRequested);
        f.mail->attachment("part-a", false); QCOMPARE(saveRequested.count(), 1);
        const auto transaction = saveRequested.first().at(0).toString();
        QVERIFY(!transaction.isEmpty());
        QCOMPARE(saveRequested.first().at(1).toUrl().fileName(), QString("note.txt"));
        const auto savedPath = directory.filePath("downloaded-note.txt");
        f.download->save(transaction, QUrl::fromLocalFile(savedPath));
        QTRY_COMPARE(f.remote.count(attachmentPath), 1);
        QCOMPARE(f.remote.methods.at(f.remote.paths.indexOf(attachmentPath)), QString("GET"));
        QTRY_VERIFY(!f.download->busy());
        QVERIFY2(f.download->error().isEmpty(), qPrintable(f.download->error()));
        QCOMPARE(f.download->status(), QString("File saved."));
        QFile downloaded(savedPath); QVERIFY(downloaded.open(QIODevice::ReadOnly));
        QCOMPARE(downloaded.readAll(), attachmentBytes);
    }

    void switchingWorkspaceClearsPrivateCompositionAndIgnoresOldResponses() {
        MailFixture f;
        f.accounts->refresh(); QTRY_COMPARE(f.accounts->accounts().size(), 2);
        QPointer<QTcpSocket> delayed;
        f.intercept = [&](QTcpSocket* socket, const QString& path) {
            if (path == "/api/mail/messages/message-a") { delayed = socket; return true; }
            return false;
        };
        f.draft(); f.mail->select("message-a"); QTRY_VERIFY(delayed);
        f.api.setWorkspace("workspace-b"); f.accounts->setActive(false); f.mail->setActive(false);
        QVERIFY(f.mail->draft().isEmpty()); QVERIFY(f.mail->selected().isEmpty()); QVERIFY(!f.mail->hasDraft());
        if (delayed) MailApi::reply(delayed, {{"data", f.detail}});
        QTest::qWait(30);
        QVERIFY(f.mail->selected().isEmpty()); QVERIFY(!f.mail->canSend());
    }
};

QTEST_MAIN(MailCenterTests)
#include "mail_center_tests.moc"
