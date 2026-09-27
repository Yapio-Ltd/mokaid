#include <mokaid/preview/document_format.hpp>
#include <QBuffer>
#include <QImage>
#include <QtTest>

using namespace mokaid::desktop;
class DocumentFormatTests final : public QObject {
    Q_OBJECT
private slots:
    void mailAttachmentsNeverPromoteActiveMarkupFromMimeOrFilename() {
        const QByteArray hostile("<html><script>alert(1)</script><img src='file:///etc/passwd'><img src='https://tracker.test/pixel'></html>");
        for (const auto& name:QStringList{"message.html","invoice.pdf","picture.png","image.svg"}) {
            const auto format=describeMailAttachment({{"name",name},{"mime_type","application/pdf"}},hostile);
            QCOMPARE(format.value("kind").toString(),"text");
            QCOMPARE(format.value("mimeType").toString(),"text/plain");
            const auto rendered=readableDocument(format,hostile);
            QVERIFY(rendered.contains("&lt;script&gt;")); QVERIFY(!rendered.contains("<script>")); QVERIFY(!rendered.contains("<img src="));
        }
        const auto svg=describeMailAttachment({{"name","safe.png"},{"mime_type","image/png"}},"<svg><image href='https://tracker.test/pixel'/></svg>");
        QCOMPARE(svg.value("kind").toString(),"text");
        QCOMPARE(describeMailAttachment({{"name","document.txt"}},QByteArray("MZ\0binary",9)).value("kind").toString(),"unsupported");
        QCOMPARE(describeMailAttachment({{"name","document.html"}},"%PDF-1.7\n").value("kind").toString(),"pdf");
    }
    void usesFilenameWhenUploaderProvidesGenericMime() {
        for (const auto& row : QList<QPair<QString, QString>>{{"photo.jpeg", "image"}, {"report.PDF", "pdf"}, {"site.html", "html"}, {"data.json", "text"}, {"report.md", "text"}, {"clip.mp4", "video"}, {"voice.mp3", "audio"}, {"budget.xlsx", "unsupported"}, {"deck.pptx", "unsupported"}, {"archive.zip", "unsupported"}}) {
            const auto result = describeDeliverable({{"name", row.first}, {"mime_type", "application/octet-stream"}});
            QCOMPARE(result.value("kind").toString(), row.second);
        }
        QCOMPARE(describeDeliverable({{"name", "BUDGET.xlsx"}}).value("label").toString(), "Spreadsheet");
        QCOMPARE(describeDeliverable({{"name", "recording"}, {"mime_type", "Audio/MPEG; charset=binary"}}).value("kind").toString(), "audio");
    }
    void attachmentsUseDriveIdentifierAndOriginalSize() {
        const auto file = normalizeDeliverable({{"id", "attachment-1"}, {"drive_item_id", "file-1"}, {"filename", "report.pdf"}, {"size_bytes", 2097152}});
        QCOMPARE(file.value("id").toString(), "file-1");
        QCOMPARE(file.value("name").toString(), "report.pdf");
        QCOMPARE(file.value("kind").toString(), "file");
        QCOMPARE(file.value("status").toString(), "active");
        QCOMPARE(describeDeliverable(file).value("sizeLabel").toString(), "2.0 MB");
    }
    void spreadsheetPreservesQuotedContentAndEscapesMarkup() {
        const auto html = readableDocument(describeDeliverable({{"name", "report.csv"}}), "Name,Notes\r\nAlice,\"One, two\nthree\"\r\nBob,\"<script> & \"\"quoted\"\"\"\n");
        QVERIFY(html.contains("<th>Name</th>"));
        QVERIFY(html.contains("<td>One, two\nthree</td>"));
        QVERIFY(html.contains("&lt;script&gt; &amp; &quot;quoted&quot;"));
        QVERIFY(!html.contains("<script>"));
    }
    void hugeSpreadsheetClearlyShowsPreviewLimit() {
        QByteArray data("A,B\n");
        for (int i = 0; i < 1100; ++i) data += "value,value\n";
        const auto html = readableDocument(describeDeliverable({{"name", "report.csv"}}), data);
        QCOMPARE(html.count("<tr>"), 1000);
        QVERIFY(html.contains("Preview limited to 1,000 rows"));
    }
    void codeIsReadableButCannotExecute() {
        const auto html = readableDocument(describeDeliverable({{"name", "code.js"}}), "<script>alert('no')</script>");
        QVERIFY(html.contains("&lt;script&gt;")); QVERIFY(!html.contains("<script>"));
        const auto json = readableDocument(describeDeliverable({{"name", "data.json"}}), "{\"name\":\"Example\"}");
        QVERIFY(json.contains("\n    &quot;name&quot;"));
    }
    void largeTextPreviewIsBoundedAndClearlyMarked() {
        const auto source = QByteArray(2 * 1024 * 1024, 'a') + "end-marker-not-in-preview";
        const auto html = readableDocument(describeDeliverable({{"name", "long-report.txt"}}), source);
        QVERIFY(html.size() < 1100 * 1024);
        QVERIFY(html.contains("Showing the beginning of this document"));
        QVERIFY(!html.contains("end-marker-not-in-preview"));
        QVERIFY(!readableDocument(describeDeliverable({{"name", "short-report.txt"}}), "Complete document").contains("Showing the beginning"));
    }
    void makesBoundedRealImageThumbnailAndRejectsNonImages() {
        QImage source(2400, 1600, QImage::Format_RGB32); source.fill(QColor("#8c7ce9"));
        QByteArray png; QBuffer output(&png); QVERIFY(output.open(QIODevice::WriteOnly)); QVERIFY(source.save(&output, "PNG"));
        const auto thumbnail = imageThumbnail(png);
        QVERIFY(!thumbnail.isEmpty());
        const auto decoded = QImage::fromData(thumbnail, "PNG");
        QCOMPARE(decoded.size(), QSize(720, 480));
        QVERIFY(imageThumbnail("<html>pretend image</html>").isEmpty());
    }
};
QTEST_GUILESS_MAIN(DocumentFormatTests)
#include "document_format_tests.moc"
