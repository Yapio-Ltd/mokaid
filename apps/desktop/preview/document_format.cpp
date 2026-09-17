#include <mokaid/preview/document_format.hpp>
#include <QBuffer>
#include <QFileInfo>
#include <QImageReader>
#include <QJsonDocument>
#include <QMimeDatabase>
#include <QTextDocument>

namespace mokaid::desktop {
QVariantMap normalizeDeliverable(QVariantMap file) {
    if (!file.value("drive_item_id").toString().isEmpty()) file.insert("id", file.value("drive_item_id"));
    if (file.value("name").toString().isEmpty()) file.insert("name", file.value("filename", "Deliverable"));
    if (file.value("mime_type").toString().isEmpty()) file.insert("mime_type", file.value("content_type"));
    file.insert("kind", "file");
    if (file.value("status").toString().isEmpty()) file.insert("status", "active");
    return file;
}
QVariantMap describeDeliverable(const QVariantMap& input) {
    const auto file = normalizeDeliverable(input);
    const auto name = file.value("name").toString();
    const auto extension = QFileInfo(name).suffix().toLower();
    auto mime = file.value("mime_type").toString().section(';', 0, 0).trimmed().toLower();
    const auto inferred = QMimeDatabase().mimeTypeForFile(name, QMimeDatabase::MatchExtension).name();
    if (mime.isEmpty() || mime == "application/octet-stream") mime = inferred;
    const QStringList code{"json", "yaml", "yml", "xml", "js", "jsx", "ts", "tsx", "css", "py", "rb", "rs", "go", "cpp", "c", "h", "hpp", "sh", "sql", "toml", "ini", "log", "txt"};
    QString kind = "unsupported", label = "File";
    if (mime.startsWith("image/") || inferred.startsWith("image/")) { kind = "image"; label = "Image"; }
    else if (mime == "application/pdf" || extension == "pdf") { kind = "pdf"; label = "PDF"; mime = "application/pdf"; }
    else if (mime == "text/html" || extension == "html" || extension == "htm") { kind = "html"; label = "Interactive page"; mime = "text/html"; }
    else if (mime.startsWith("audio/")) { kind = "audio"; label = "Audio"; }
    else if (mime.startsWith("video/")) { kind = "video"; label = "Video"; }
    else if (mime.startsWith("text/") || code.contains(extension) || extension == "md" || extension == "markdown") {
        kind = "text"; label = "Document";
        if (extension == "md" || extension == "markdown" || mime == "text/markdown") { label = "Markdown"; mime = "text/markdown"; }
        else if (extension == "csv" || extension == "tsv") label = "Spreadsheet";
        else if (code.contains(extension) && extension != "txt" && extension != "log") label = "Code";
    } else if (QStringList{"doc", "docx", "odt", "rtf", "pages"}.contains(extension)) label = "Document";
    else if (QStringList{"xls", "xlsx", "ods", "numbers"}.contains(extension)) label = "Spreadsheet";
    else if (QStringList{"ppt", "pptx", "odp", "key"}.contains(extension)) label = "Presentation";
    else if (QStringList{"zip", "tar", "gz", "7z", "rar"}.contains(extension)) label = "Archive";
    const auto size = file.value("size_bytes").toLongLong();
    QString sizeLabel;
    if (size > 0) sizeLabel = size < 1024 ? QString::number(size) + " B" : size < 1024 * 1024
        ? QString::number(static_cast<double>(size) / 1024, 'f', 0) + " KB"
        : QString::number(static_cast<double>(size) / (1024 * 1024), 'f', 1) + " MB";
    return {{"kind", kind}, {"label", label}, {"mimeType", mime}, {"extension", extension.toUpper()}, {"sizeLabel", sizeLabel}};
}
namespace {
QByteArray page(const QByteArray& body, const QByteArray& extra = {}) {
    return "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><style>"
        "*{box-sizing:border-box}body{margin:0;background:#fff;color:#202431;font:16px/1.65 -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif}"
        "main{max-width:920px;margin:auto;padding:48px 56px 80px}h1,h2,h3{line-height:1.25;letter-spacing:-.02em}h1{font-size:36px}h2{margin-top:1.7em}"
        "a{color:#6552d9}pre,code{font-family:ui-monospace,SFMono-Regular,Consolas,monospace;font-size:13px}pre{white-space:pre-wrap;overflow-wrap:anywhere;padding:24px;border-radius:12px;background:#f6f7fa}"
        "code{background:#f6f7fa;border-radius:4px;padding:2px 4px}pre code{padding:0}img{max-width:100%;height:auto}blockquote{margin-left:0;padding:4px 20px;border-left:3px solid #b5acd9;color:#606575}"
        "table{width:100%;border-collapse:collapse;font-size:14px}th,td{padding:11px 16px;text-align:left;border-bottom:1px solid #e8eaf0;vertical-align:top;white-space:pre-wrap}"
        "thead{position:sticky;top:0;background:#f4f5f9}tbody tr:nth-child(even){background:#fafbfc}.sheet{max-width:none;padding:0 0 32px;overflow-x:auto}.note{color:#747989;font-size:13px;padding:16px}"
        "@media(max-width:640px){main{padding:24px}h1{font-size:28px}}" + extra + "</style></head><body>" + body + "</body></html>";
}
QByteArray table(const QString& source, QChar separator) {
    QList<QStringList> rows;
    QStringList row; QString cell; bool quoted = false, clipped = false;
    // A bounded reader keeps a huge CSV usable while preserving quoted fields/newlines.
    for (qsizetype i = 0; i < source.size(); ++i) {
        const auto c = source[i];
        if (c == '"') {
            if (quoted && i + 1 < source.size() && source[i + 1] == '"') { cell += '"'; ++i; }
            else if (quoted || cell.isEmpty()) quoted = !quoted;
            else cell += c;
        } else if (!quoted && (c == separator || c == '\n')) {
            if (row.size() < 100) row.append(cell); else clipped = true;
            cell.clear();
            if (c == '\n') { rows.append(row); row.clear(); if (rows.size() >= 1000) { clipped |= i + 1 < source.size(); break; } }
        } else if (c != '\r' || quoted) cell += c;
    }
    if (rows.size() < 1000 && (!cell.isEmpty() || !row.isEmpty())) { if (row.size() < 100) row.append(cell); rows.append(row); }
    QByteArray html = "<main class=\"sheet\"><table>";
    for (qsizetype i = 0; i < rows.size(); ++i) {
        if (i == 0) html += "<thead>";
        if (i == 1) html += "<tbody>";
        html += "<tr>";
        const QByteArray tag = i == 0 ? "th" : "td";
        for (const auto& value : rows[i]) html += '<' + tag + '>' + value.toHtmlEscaped().toUtf8() + "</" + tag + '>';
        html += "</tr>";
        if (i == 0) html += "</thead>";
    }
    if (rows.size() > 1) html += "</tbody>";
    html += "</table>";
    if (clipped) html += "<p class=\"note\">Preview limited to 1,000 rows and 100 columns. Download the original for the complete spreadsheet.</p>";
    return page(html + "</main>");
}
}
QByteArray readableDocument(const QVariantMap& format, const QByteArray& bytes) {
    constexpr qsizetype maximumText = 1024 * 1024;
    const auto content = bytes.left(maximumText);
    const auto markTruncated = [&](QByteArray html) {
        if (bytes.size() > maximumText) html.replace("<body>", "<body><p class=\"note\" role=\"status\">Showing the beginning of this document. Download the original to read everything.</p>");
        return html;
    };
    const auto extension = format.value("extension").toString().toLower();
    if (extension == "csv" || extension == "tsv") return markTruncated(table(QString::fromUtf8(content), extension == "tsv" ? '\t' : ','));
    if (format.value("mimeType") == "text/markdown") {
        QTextDocument document; document.setMarkdown(QString::fromUtf8(content));
        auto html = document.toHtml();
        const auto start = html.indexOf('>', html.indexOf("<body")) + 1;
        html = html.mid(start, html.lastIndexOf("</body>") - start);
        return markTruncated(page("<main>" + html.toUtf8() + "</main>"));
    }
    auto text = content;
    if (extension == "json") { const auto json = QJsonDocument::fromJson(content); if (!json.isNull()) text = json.toJson(QJsonDocument::Indented); }
    return markTruncated(page("<main><pre>" + QString::fromUtf8(text).toHtmlEscaped().toUtf8() + "</pre></main>"));
}
QByteArray imageThumbnail(const QByteArray& bytes) {
    QBuffer buffer; buffer.setData(bytes); buffer.open(QIODevice::ReadOnly);
    QImageReader reader(&buffer); reader.setAutoTransform(true);
    const auto size = reader.size();
    if (!size.isValid() || static_cast<qint64>(size.width()) * size.height() > 32 * 1024 * 1024) return {};
    reader.setScaledSize(size.scaled(720, 480, Qt::KeepAspectRatio));
    auto image = reader.read(); if (image.isNull()) return {};
    if (image.width() > 720 || image.height() > 480) image = image.scaled(720, 480, Qt::KeepAspectRatio, Qt::SmoothTransformation);
    QByteArray result; QBuffer destination(&result); destination.open(QIODevice::WriteOnly);
    if (!image.save(&destination, "PNG") || result.size() > 2 * 1024 * 1024) return {};
    return result;
}
}
