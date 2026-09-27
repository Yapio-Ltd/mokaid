#include <mokaid/features/mail_center_controller.hpp>
#include <QFile>
#include <QFileInfo>
#include <QMimeDatabase>
#include <QRegularExpression>
#include <QTextBlock>
#include <QTextDocument>
#include <QTextFragment>
#include <QTextList>
#include <QUrlQuery>
#include <QUuid>

namespace mokaid::desktop {
namespace {
QString encoded(const QString& value) { return QString::fromLatin1(QUrl::toPercentEncoding(value)); }
bool validId(const QString& id) { return QRegularExpression("^[A-Za-z0-9][A-Za-z0-9_-]{0,511}$").match(id).hasMatch(); }
QVariantMap message(const QJsonObject& raw, bool detail = false) {
    QVariantMap safe;
    for (const auto* key : {"id","mail_account_id","from_name","from_email","to_emails","cc_emails","subject","snippet","folder","labels","has_attachments","received_at","is_read","is_starred","ai_category","ai_importance","ai_summary","attachments"})
        if (raw.contains(key)) safe.insert(key,raw.value(key).toVariant());
    if (detail) {
        safe.insert("body_text",raw.value("body_text").toString().left(200000));
        safe.insert("safe_body",MailCenterController::safeBody(raw.value("body_html").toString(),raw.value("body_text").toString()));
    }
    return safe;
}
class InertDocument final : public QTextDocument {
    QVariant loadResource(int, const QUrl&) override { return {}; }
};
QJsonArray recipients(const QString& source, bool& valid) {
    QJsonArray result;
    static const QRegularExpression email("^[^\\s<>@,;]+@[^\\s<>@,;]+\\.[^\\s<>@,;]+$");
    for (const auto& part : source.split(QRegularExpression("[,;\\n]"),Qt::SkipEmptyParts)) {
        const auto value=part.trimmed();
        if (!email.match(value).hasMatch() || value.contains('\r')) valid=false;
        result.append(value);
    }
    return result;
}
}
bool MailCenterController::safeLink(const QUrl& url) {
    if (!url.isValid() || !url.userInfo().isEmpty() || url.toString().contains(QRegularExpression("[\\x00-\\x1f\\x7f]"))) return false;
    if (url.scheme()=="mailto") return !url.path().isEmpty() && !url.hasQuery() && !url.hasFragment();
    return (url.scheme()=="https" || url.scheme()=="http") && !url.host().isEmpty();
}
QString MailCenterController::safeBody(const QString& html, const QString& plain) {
    if (html.isEmpty()) return "<p>"+plain.left(200000).toHtmlEscaped().replace('\n',"<br>")+"</p>";
    // Parse HTML with Qt's inert document parser, then rebuild from text runs.
    // Original markup/attributes never reach QML, including image resources,
    // CSS URLs, embedded documents, forms and event handlers.
    InertDocument document; document.setHtml(html.left(200000));
    QString result;
    for (auto block=document.begin();block.isValid();block=block.next()) {
        result+="<p style=\"margin:0 0 14px\">";
        if (block.textList()) result+="&#8226; ";
        for (auto it=block.begin();!it.atEnd();++it) {
            const auto fragment=it.fragment(); if (!fragment.isValid()) continue;
            const auto format=fragment.charFormat();
            if (format.isImageFormat()) { result+="<i>[Image omitted]</i>"; continue; }
            auto text=fragment.text().toHtmlEscaped().replace(QChar::LineSeparator,"<br>");
            if (format.fontWeight()>=QFont::DemiBold) text="<b>"+text+"</b>";
            if (format.fontItalic()) text="<i>"+text+"</i>";
            if (format.fontUnderline()) text="<u>"+text+"</u>";
            if (format.fontStrikeOut()) text="<s>"+text+"</s>";
            if (format.fontPointSize()>15) text="<span style=\"font-size:18px\">"+text+"</span>";
            const QUrl link(format.anchorHref());
            if (format.isAnchor() && safeLink(link)) text="<a href=\""+link.toString(QUrl::FullyEncoded).toHtmlEscaped()+"\">"+text+"</a>";
            result+=text;
        }
        result+="</p>";
    }
    return result;
}
MailCenterController::MailCenterController(ApiClient& api, SessionController& session, MailAccountsController& accounts, DriveDownload& download, QObject* parent)
    : QObject(parent), api_(api), accounts_(accounts), download_(download), generation_(api.context().generation) {
    searchTimer_.setSingleShot(true); searchTimer_.setInterval(250);
    connect(&searchTimer_,&QTimer::timeout,this,&MailCenterController::refresh);
    connect(&session,&SessionController::changed,this,&MailCenterController::syncContext);
    connect(&session,&SessionController::workspaceChanged,this,&MailCenterController::syncContext);
    connect(&session,&SessionController::cleared,this,&MailCenterController::syncContext);
    connect(&accounts,&MailAccountsController::changed,this,[this]{emit changed();});
    connect(&accounts,&MailAccountsController::selectionChanged,this,[this]{closeMessage(); if(active_) refresh();});
    connect(&accounts,&MailAccountsController::messagesChanged,this,[this]{if(active_) refresh();});
    connect(&api,&ApiClient::onlineChanged,this,[this]{syncContext(); emit changed(); if(online()&&active_) refresh();});
}
MailCenterController::~MailCenterController() { for(auto* owner:{&listOwner_,&folderOwner_,&detailOwner_,&actionOwner_,&sendOwner_}) api_.cancelRequests(owner); }
void MailCenterController::syncContext() {
    if(generation_==api_.context().generation) return;
    generation_=api_.context().generation; ++listRevision_; ++detailRevision_;
    for(auto* owner:{&listOwner_,&folderOwner_,&detailOwner_,&actionOwner_,&sendOwner_}) api_.cancelRequests(owner);
    searchTimer_.stop(); messages_.clear(); folders_.clear(); labels_.clear(); selected_.clear(); selectedId_.clear();
    draft_.clear(); outgoingAttachments_={}; submitted_={}; requestId_.clear(); outboxId_.clear(); submissionAttempts_=0; error_.clear(); notice_.clear();
    folder_="inbox"; filter_="all"; sort_="newest"; query_.clear(); label_.clear();
    busy_=detailLoading_=mutating_=hasMore_=composing_=sending_=uncertain_=sendFailed_=false;
    emit contextReset(); emit changed();
}
void MailCenterController::fail(const QString& error) { error_=error; emit changed(); }
void MailCenterController::setActive(bool active) { syncContext(); active_=active; if(active) refresh(); }
void MailCenterController::refresh() { syncContext(); searchTimer_.stop(); if(!online()) {emit changed(); return;} fetchMessages(false); fetchFolders(); }
void MailCenterController::fetchMessages(bool more) {
    if(!online() || (more&&busy_)) return;
    api_.cancelRequests(&listOwner_); const auto revision=++listRevision_; const auto generation=generation_;
    const int offset=more?static_cast<int>(messages_.size()):0;
    QUrlQuery query; query.addQueryItem("folder",folder_); query.addQueryItem("filter",filter_); query.addQueryItem("sort",sort_);
    query.addQueryItem("limit","50"); query.addQueryItem("offset",QString::number(offset));
    if(!accounts_.selectedId().isEmpty()) query.addQueryItem("account_id",accounts_.selectedId());
    if(!query_.isEmpty()) query.addQueryItem("q",query_);
    if(!label_.isEmpty()) query.addQueryItem("label",label_);
    busy_=true; error_.clear(); emit changed();
    api_.request("GET","/api/mail/messages?"+query.toString(QUrl::FullyEncoded),{},core::Scope::workspace,&listOwner_,[this,revision,generation,more](ApiResponse response){
        if(generation!=api_.context().generation || revision!=listRevision_) return;
        busy_=false; if(!response.ok()) {fail(response.error); return;}
        QVariantList rows=more?messages_:QVariantList{};
        for(const auto& value:response.json.value("data").toArray()) rows.append(message(value.toObject()));
        messages_=rows; hasMore_=response.json.value("meta").toObject().value("has_more").toBool(); emit changed();
        if(selectedId_.isEmpty()&&!messages_.isEmpty()&&!composing_) select(messages_.first().toMap().value("id").toString());
    });
}
void MailCenterController::fetchFolders() {
    api_.cancelRequests(&folderOwner_); const auto generation=generation_;
    const auto path=QString("/api/mail/folders")+(accounts_.selectedId().isEmpty()?QString{}:"?account_id="+encoded(accounts_.selectedId()));
    api_.request("GET",path,{},core::Scope::workspace,&folderOwner_,[this,generation](ApiResponse response){
        if(generation!=api_.context().generation || !response.ok()) return;
        folders_=response.json.value("data").toArray().toVariantList(); labels_=response.json.value("meta").toObject().value("labels").toArray().toVariantList(); emit changed();
    });
}
void MailCenterController::loadMore() { if(hasMore_) fetchMessages(true); }
void MailCenterController::setFolder(const QString& folder) {
    if(!QStringList{"inbox","starred","sent","drafts","spam","trash","all"}.contains(folder)) return;
    folder_=folder; label_.clear(); closeMessage(); messages_.clear(); refresh();
}
void MailCenterController::setFilter(const QString& value) { if(!QStringList{"all","unread","flagged"}.contains(value)||filter_==value) return; filter_=value; closeMessage(); refresh(); }
void MailCenterController::setSort(const QString& value) { if(!QStringList{"newest","oldest","sender","subject"}.contains(value)||sort_==value) return; sort_=value; refresh(); }
void MailCenterController::search(const QString& value) { query_=value.left(500); closeMessage(); searchTimer_.start(); emit changed(); }
void MailCenterController::setLabel(const QString& name) { label_=name.left(200); folder_="all"; closeMessage(); refresh(); }
void MailCenterController::closeMessage() { ++detailRevision_; api_.cancelRequests(&detailOwner_); selectedId_.clear(); selected_.clear(); detailLoading_=false; emit changed(); }
void MailCenterController::select(const QString& id) {
    syncContext(); if(!validId(id)||!online()) return;
    api_.cancelRequests(&detailOwner_); const auto revision=++detailRevision_; const auto generation=generation_;
    selectedId_=id; selected_.clear(); for(const auto& row:messages_) if(row.toMap().value("id")==id) selected_=row.toMap();
    detailLoading_=true; error_.clear(); emit changed();
    api_.request("GET","/api/mail/messages/"+encoded(id),{},core::Scope::workspace,&detailOwner_,[this,generation,revision,id](ApiResponse response){
        if(generation!=api_.context().generation || revision!=detailRevision_ || selectedId_!=id) return;
        detailLoading_=false; if(!response.ok()) {fail(response.error); return;}
        selected_=message(response.json.value("data").toObject(),true);
        if (!response.json.value("meta").toObject().value("hydration_error").toString().isEmpty()) selected_.insert("hydration_error", "Some message content or attachments could not be loaded. Retry when your mailbox is available.");
        emit changed();
    });
}
void MailCenterController::replaceMessage(const QVariantMap& update) {
    const auto id=update.value("id").toString();
    for(auto& row:messages_) if(row.toMap().value("id")==id) {auto merged=row.toMap(); for(auto it=update.begin();it!=update.end();++it) merged.insert(it.key(),it.value()); row=merged;}
    if(selectedId_==id) for(auto it=update.begin();it!=update.end();++it) selected_.insert(it.key(),it.value());
}
void MailCenterController::act(const QString& action, bool value, const QString& requestedId) {
    if(!canManage()||mutating_||!QStringList{"read","star","archive","spam","trash"}.contains(action)) return;
    const auto id=requestedId.isEmpty()?selectedId_:requestedId; if(!validId(id)) return;
    bool known=id==selectedId_; for(const auto& row:messages_) known|=row.toMap().value("id")==id; if(!known) return;
    const auto generation=generation_; mutating_=true; error_.clear(); emit changed();
    api_.request("PATCH","/api/mail/messages/"+encoded(id),{{"action",action},{"value",value}},core::Scope::workspace,&actionOwner_,[this,generation,action,id](ApiResponse response){
        if(generation!=api_.context().generation) return;
        mutating_=false; if(!response.ok()) {fail(response.error); return;}
        replaceMessage(message(response.json.value("data").toObject())); emit changed(); fetchFolders();
        if(action=="archive"||action=="spam"||action=="trash") {if(selectedId_==id) closeMessage(); fetchMessages(false);}
    });
}
void MailCenterController::attachment(const QString& id,bool preview) {
    if(!online()||selectedId_.isEmpty()||!validId(id)) return;
    for(const auto& value:selected_.value("attachments").toList()) {
        const auto item=value.toMap(); if(item.value("id").toString()!=id) continue;
        const auto key=QUuid::createUuidV5(QUuid("78dc783a-6678-44df-8e1d-724a7e711c5f"),(selectedId_+":"+id).toUtf8()).toString(QUuid::WithoutBraces);
        const QVariantMap file{{"id",key},{"name",item.value("filename")},{"mime_type",item.value("mime_type")},{"size_bytes",item.value("size")},
            {"kind","file"},{"status","active"},{"mail_message_id",selectedId_},{"mail_attachment_id",id}};
        if(preview) emit openAttachment(file); else download_.request(file);
        return;
    }
}
void MailCenterController::openLink(const QUrl& url) { if(safeLink(url)) emit requestExternal(url); }
QVariantList MailCenterController::draftAttachments() const { QVariantList result; for(const auto& value:outgoingAttachments_) {const auto file=value.toObject(); result.append(QVariantMap{{"filename",file.value("filename").toString()},{"size",file.value("size").toInt()}});} return result; }
bool MailCenterController::hasDraft() const { return sending_||uncertain_||!outgoingAttachments_.isEmpty()||!draft_.value("to").toString().isEmpty()||!draft_.value("cc").toString().isEmpty()||!draft_.value("bcc").toString().isEmpty()||!draft_.value("subject").toString().isEmpty()||!draft_.value("body_text").toString().isEmpty(); }
void MailCenterController::compose(bool reply) {
    if(hasDraft()) {composing_=true; emit changed(); return;}
    QString account=accounts_.selectedId(); if(reply) account=selected_.value("mail_account_id").toString();
    if(account.isEmpty()&&!accounts_.accounts().isEmpty()) account=accounts_.accounts().first().toMap().value("id").toString();
    draft_={{"account_id",account},{"to",reply?selected_.value("from_email").toString():QString{}},{"cc",""},{"bcc",""},{"subject",""},{"body_text",""}};
    if(reply&&!selectedId_.isEmpty()) {const auto subject=selected_.value("subject").toString(); draft_.insert("subject",subject.startsWith("Re:",Qt::CaseInsensitive)?subject:"Re: "+subject); draft_.insert("in_reply_to",selectedId_);}
    composing_=true; error_.clear(); notice_.clear(); emit changed();
}
void MailCenterController::closeComposer() { composing_=false; emit changed(); }
void MailCenterController::discardDraft() {
    if(sending_||uncertain_) return;
    draft_.clear(); outgoingAttachments_={}; submitted_={}; requestId_.clear(); outboxId_.clear(); submissionAttempts_=0; composing_=sendFailed_=false; error_.clear(); notice_.clear(); emit changed();
}
void MailCenterController::setDraft(const QString& key,const QString& value) {
    if(sending_||uncertain_||!QStringList{"account_id","to","cc","bcc","subject","body_text"}.contains(key)) return;
    if(draft_.value(key).toString()==value) return;
    draft_.insert(key,value.left(key=="body_text"?200000:QStringList{"to","cc","bcc"}.contains(key)?32000:2000)); emit changed();
}
void MailCenterController::addAttachments(const QList<QUrl>& urls) {
    if(sending_||uncertain_) return;
    auto files=outgoingAttachments_; qint64 total=0; for(const auto& value:files) total+=value.toObject().value("size").toInteger();
    for(const auto& url:urls) {
        QFileInfo info(url.toLocalFile());
        if(!url.isLocalFile()||!url.host().isEmpty()||info.isSymLink()||!info.isFile()||!info.isReadable()) {fail("Choose a readable local file to attach."); return;}
        if(files.size()>=10||info.size()>5*1024*1024-total) {fail("Attach up to 10 files, totaling no more than 5 MB."); return;}
        QFile file(info.absoluteFilePath()); if(!file.open(QIODevice::ReadOnly)) {fail("This file could not be opened."); return;}
        const auto bytes=file.read(5*1024*1024-total+1); if(bytes.size()>5*1024*1024-total) {fail("Attachments exceed the 5 MB limit."); return;}
        total+=bytes.size(); files.append(QJsonObject{{"filename",DriveDownload::safeFileName(info.fileName())},{"content_type",QMimeDatabase().mimeTypeForFile(info).name()},{"content_base64",QString::fromLatin1(bytes.toBase64())},{"size",bytes.size()}});
    }
    outgoingAttachments_=files; error_.clear(); emit changed();
}
void MailCenterController::removeAttachment(int index) { if(!sending_&&!uncertain_&&index>=0&&index<outgoingAttachments_.size()) {outgoingAttachments_.removeAt(index); emit changed();} }
void MailCenterController::send() {
    syncContext(); if(!canSend()||sending_) return;
    if(uncertain_) {checkDelivery(); return;}
    bool valid=true; const auto to=recipients(draft_.value("to").toString(),valid),cc=recipients(draft_.value("cc").toString(),valid),bcc=recipients(draft_.value("bcc").toString(),valid);
    if(!valid||to.isEmpty()||to.size()+cc.size()+bcc.size()>100) {fail("Enter valid email addresses separated by commas, with no more than 100 recipients."); return;}
    bool known=false; for(const auto& account:accounts_.accounts()) known|=account.toMap().value("id")==draft_.value("account_id");
    if(!known) {fail("Choose a connected mailbox to send from."); return;}
    const auto subject=draft_.value("subject").toString(),body=draft_.value("body_text").toString();
    if(subject.contains('\r')||subject.contains('\n')||subject.toUtf8().size()>998||body.toUtf8().size()>200000||body.trimmed().isEmpty()) {fail("Write your message before sending. Subject: up to 998 characters; message: up to 200 KB."); return;}
    if(requestId_.isEmpty()||sendFailed_) {requestId_=QUuid::createUuid().toString(QUuid::WithoutBraces);outboxId_.clear();submissionAttempts_=0;}
    sendFailed_=false; submitted_={{"request_id",requestId_},{"account_id",draft_.value("account_id").toString()},{"to",to},{"cc",cc},{"bcc",bcc},{"subject",subject},{"body_text",body}};
    if(!draft_.value("in_reply_to").toString().isEmpty()) submitted_.insert("in_reply_to",draft_.value("in_reply_to").toString());
    QJsonArray files; for(const auto& value:outgoingAttachments_) {auto file=value.toObject();file.remove("size");files.append(file);} submitted_.insert("attachments",files);
    uncertain_=true; checkDelivery();
}
void MailCenterController::checkDelivery() {
    if(!online()||sending_||!uncertain_||submitted_.isEmpty()) return;
    sending_=true; error_.clear(); notice_="Sending your message…"; emit changed(); const auto generation=generation_;
    const bool firstSubmission=outboxId_.isEmpty() && submissionAttempts_==0;
    if(outboxId_.isEmpty()) ++submissionAttempts_;
    api_.request(outboxId_.isEmpty()?"POST":"GET",outboxId_.isEmpty()?"/api/mail/send":"/api/mail/outbox/"+encoded(outboxId_),outboxId_.isEmpty()?submitted_:QJsonObject{},core::Scope::workspace,&sendOwner_,[this,generation,firstSubmission](ApiResponse response){
        if(generation!=api_.context().generation) return;
        sending_=false;
        if(!response.ok()) {
            notice_.clear();
            if(firstSubmission && QList<int>{400,401,403,404,422}.contains(response.status)) {
                uncertain_=false; sendFailed_=true; fail(response.error+" Your draft is retained."); return;
            }
            fail("Delivery is unconfirmed. Check Sent or use Check delivery. Your draft is retained; checking will not send a duplicate.");
            return;
        }
        finishSend(response.json.value("data").toObject());
    });
}
void MailCenterController::finishSend(const QJsonObject& data) {
    if(data.value("request_id").toString()!=requestId_||data.value("id").toString().isEmpty()) {fail("Delivery is unconfirmed. Check Sent before sending again. Your draft has been retained.");return;}
    outboxId_=data.value("id").toString(); const auto status=data.value("status").toString();
    if(status=="sent") {uncertain_=false;discardDraft();notice_="Message sent.";refresh();}
    else if(status=="failed") {uncertain_=false;sendFailed_=true;notice_.clear();fail("The message was not sent. Check your mailbox connection, then try again. Your draft is retained.");}
    else {uncertain_=true;notice_="Delivery is unconfirmed. Check Sent or check delivery before sending again.";}
    emit changed();
}
}
