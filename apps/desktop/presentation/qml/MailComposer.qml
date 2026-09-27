pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import "MailLogic.js" as Mail

Rectangle {
    id:root
    required property var controller
    required property var accounts
    readonly property bool locked:controller.sending || controller.deliveryUncertain
    property bool copies:!!controller.draft.cc || !!controller.draft.bcc
    color:Theme.surface; radius:14; border.color:Theme.selectedBorder
    ColumnLayout {
        anchors.fill:parent; anchors.margins:18; spacing:12
        RowLayout {
            Layout.fillWidth:true
            MokaidLabel { Layout.fillWidth:true; text:root.controller.draft.in_reply_to ? "Reply" : "New message"; font.pixelSize:20; font.weight:Font.DemiBold }
            MokaidButton { objectName:"mailCloseComposer"; iconName:"close"; quiet:true; implicitWidth:32; implicitHeight:32; Accessible.name:"Close composer and keep draft"; onClicked:root.controller.closeComposer() }
        }
        ScrollView {
            id:fields; Layout.fillWidth:true; Layout.fillHeight:true; contentWidth:availableWidth; clip:true
            ColumnLayout {
                width:fields.availableWidth; spacing:12
                RowLayout {
                    Layout.fillWidth:true; spacing:10
                    MokaidLabel { text:"From"; Layout.preferredWidth:44; color:Theme.secondary; font.pixelSize:12 }
                    MokaidComboBox { objectName:"mailDraftFrom"; Layout.fillWidth:true; model:root.accounts.accounts; textRole:"email_address"; valueRole:"id"; currentIndex:root.accounts.accounts.findIndex(function(a){return a.id===root.controller.draft.account_id;}); enabled:!root.locked&&!root.controller.draft.in_reply_to; onActivated:root.controller.setDraft("account_id",currentValue); Accessible.name:"Send from mailbox" }
                }
                RowLayout {
                    Layout.fillWidth:true; spacing:10
                    MokaidLabel { text:"To"; Layout.preferredWidth:44; color:Theme.secondary; font.pixelSize:12 }
                    MokaidTextField { objectName:"mailDraftTo"; Layout.fillWidth:true; placeholderText:"name@example.com"; text:root.controller.draft.to || ""; enabled:!root.locked; onTextEdited:root.controller.setDraft("to",text); Accessible.name:"To recipients" }
                    MokaidButton { text:"Cc / Bcc"; quiet:true; onClicked:root.copies=!root.copies; Accessible.name:"Show copy recipients" }
                }
                RowLayout {
                    visible:root.copies; Layout.fillWidth:true; spacing:10
                    MokaidLabel { text:"Cc"; Layout.preferredWidth:44; color:Theme.secondary; font.pixelSize:12 }
                    MokaidTextField { objectName:"mailDraftCc"; Layout.fillWidth:true; placeholderText:"Copy recipients"; text:root.controller.draft.cc || ""; enabled:!root.locked; onTextEdited:root.controller.setDraft("cc",text); Accessible.name:"Cc recipients" }
                }
                RowLayout {
                    visible:root.copies; Layout.fillWidth:true; spacing:10
                    MokaidLabel { text:"Bcc"; Layout.preferredWidth:44; color:Theme.secondary; font.pixelSize:12 }
                    MokaidTextField { objectName:"mailDraftBcc"; Layout.fillWidth:true; placeholderText:"Hidden recipients"; text:root.controller.draft.bcc || ""; enabled:!root.locked; onTextEdited:root.controller.setDraft("bcc",text); Accessible.name:"Bcc recipients" }
                }
                MokaidTextField { objectName:"mailDraftSubject"; Layout.fillWidth:true; placeholderText:"Subject"; text:root.controller.draft.subject || ""; enabled:!root.locked; maximumLength:998; onTextEdited:root.controller.setDraft("subject",text); Accessible.name:"Subject" }
                TextArea {
                    id:body; objectName:"mailDraftBody"; Layout.fillWidth:true; Layout.minimumHeight:240; Layout.preferredHeight:Math.max(240,contentHeight+28)
                    placeholderText:"Write your message…"; text:root.controller.draft.body_text || ""; readOnly:root.locked
                    wrapMode:TextArea.Wrap; textFormat:TextEdit.PlainText; selectByMouse:true; color:Theme.text; placeholderTextColor:Theme.muted; selectionColor:Theme.selection; selectedTextColor:"white"
                    font.family:Theme.fontFamily; font.pixelSize:13; padding:14
                    background:Rectangle { color:Theme.deep; radius:10; border.color:body.activeFocus ? Theme.focusBorder : Theme.border }
                    onTextChanged:if(activeFocus) root.controller.setDraft("body_text",text)
                    Accessible.name:"Message text"
                }
                Repeater {
                    model:root.controller.draftAttachments
                    RowLayout {
                        id:attachment; required property var modelData; required property int index; Layout.fillWidth:true
                        MokaidIcon { name:"attachment"; size:17 }
                        MokaidLabel { Layout.fillWidth:true; text:attachment.modelData.filename; elide:Text.ElideMiddle; font.pixelSize:12 }
                        MokaidLabel { text:Mail.size(attachment.modelData.size); color:Theme.secondary; font.pixelSize:11 }
                        MokaidButton { iconName:"close"; quiet:true; implicitHeight:28; implicitWidth:28; enabled:!root.locked; Accessible.name:"Remove "+attachment.modelData.filename; onClicked:root.controller.removeAttachment(attachment.index) }
                    }
                }
                MokaidLabel { Layout.fillWidth:true; text:root.controller.deliveryUncertain ? "Delivery is unconfirmed. Check Sent or check delivery before sending again. This draft stays locked to prevent duplicate messages." : "Draft kept while this workspace stays open. Attach up to 10 files, 5 MB total."; color:root.controller.deliveryUncertain ? Theme.warning : Theme.muted; wrapMode:Text.Wrap; font.pixelSize:11 }
            }
        }
        MokaidLabel { visible:!root.controller.canSend; Layout.fillWidth:true; text:root.controller.online ? "Sending requires permission from your workspace administrator." : "Reconnect to send. Your draft is kept here."; wrapMode:Text.Wrap; color:Theme.warning; font.pixelSize:12 }
        RowLayout {
            Layout.fillWidth:true; spacing:8
            MokaidButton { objectName:"mailAttachFiles"; iconName:"attachment"; text:root.width>500 ? "Attach files" : ""; quiet:true; enabled:!root.locked; Accessible.name:"Attach files"; onClicked:attachFiles.open() }
            MokaidButton { objectName:"mailDiscardDraft"; iconName:"trash"; quiet:true; enabled:!root.locked; Accessible.name:"Discard draft"; onClicked:discard.open() }
            Item { Layout.fillWidth:true }
            MokaidButton { objectName:"mailSendButton"; text:root.controller.sending ? "Sending…" : root.controller.deliveryUncertain ? "Check delivery" : "Send"; iconName:root.controller.deliveryUncertain ? "refresh" : "send"; highlighted:true; enabled:root.controller.online&&!root.controller.sending&&(root.controller.deliveryUncertain || root.controller.canSend); onClicked:root.controller.deliveryUncertain ? root.controller.checkDelivery() : root.controller.send() }
        }
    }
    FileDialog { id:attachFiles; title:"Attach files"; fileMode:FileDialog.OpenFiles; onAccepted:root.controller.addAttachments(selectedFiles) }
    MokaidDialog {
        id:discard; title:"Discard this draft?"; width:Math.min(420,root.width-40)
        ColumnLayout { width:parent.width; spacing:18
            MokaidLabel { Layout.fillWidth:true; text:"The message and its attachments will be removed from this composer."; wrapMode:Text.Wrap; color:Theme.secondary }
            RowLayout { Layout.alignment:Qt.AlignRight; MokaidButton { text:"Keep draft"; onClicked:discard.close() } MokaidButton { text:"Discard"; onClicked:{root.controller.discardDraft();discard.close();} } }
        }
    }
}
