pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "MailLogic.js" as Mail

Rectangle {
    id:root
    required property var controller
    property bool compact:false
    signal replyRequested()
    signal backRequested()
    readonly property var message:controller.selected
    color:Theme.surface; radius:14; border.color:Theme.border
    ColumnLayout {
        anchors.fill:parent; anchors.margins:16; spacing:14
        RowLayout {
            Layout.fillWidth:true; spacing:7
            MokaidButton { visible:root.compact; objectName:"mailBackToMessages"; iconName:"chevron-left"; quiet:true; implicitWidth:34; implicitHeight:34; Accessible.name:"Back to messages"; onClicked:root.backRequested() }
            Item { Layout.fillWidth:true }
            MokaidButton { objectName:"mailReplyAction"; iconName:"reply"; quiet:true; implicitWidth:34; implicitHeight:34; enabled:!!root.controller.selectedId; Accessible.name:"Reply"; onClicked:root.replyRequested() }
            MokaidButton { objectName:"mailArchiveAction"; iconName:"archive"; quiet:true; implicitWidth:34; implicitHeight:34; enabled:root.controller.canManage&&!!root.controller.selectedId&&!root.controller.mutating; Accessible.name:"Archive message"; onClicked:root.controller.act("archive") }
            MokaidButton { objectName:"mailTrashAction"; iconName:"trash"; quiet:true; implicitWidth:34; implicitHeight:34; enabled:root.controller.canManage&&!!root.controller.selectedId&&!root.controller.mutating; Accessible.name:"Move to Trash"; onClicked:root.controller.act("trash") }
            MokaidButton { objectName:"mailReadAction"; iconName:"mail"; quiet:true; implicitWidth:34; implicitHeight:34; enabled:root.controller.canManage&&!!root.controller.selectedId&&!root.controller.mutating; Accessible.name:root.message.is_read ? "Mark unread" : "Mark read"; onClicked:root.controller.act("read",!root.message.is_read) }
            MokaidButton { iconName:"more"; quiet:true; implicitWidth:34; implicitHeight:34; enabled:!!root.controller.selectedId; Accessible.name:"More message actions"; onClicked:actions.openFor(this) }
        }
        ScrollView {
            id:readerScroll; objectName:"mailReaderScroll"
            Layout.fillWidth:true; Layout.fillHeight:true; clip:true; contentWidth:availableWidth
            ColumnLayout {
                width:readerScroll.availableWidth; spacing:16
                visible:!!root.controller.selectedId
                RowLayout {
                    Layout.fillWidth:true; spacing:12
                    Rectangle { Layout.preferredWidth:42; Layout.preferredHeight:42; radius:12; color:"#3b2b58"; MokaidLabel { anchors.centerIn:parent; text:Mail.initials(root.message); color:"#e8dbff"; font.pixelSize:16; font.weight:Font.DemiBold } }
                    ColumnLayout {
                        Layout.fillWidth:true; spacing:4
                        MokaidLabel { Layout.fillWidth:true; text:Mail.sender(root.message); font.weight:Font.DemiBold; font.pixelSize:13; elide:Text.ElideRight }
                        MokaidLabel { Layout.fillWidth:true; text:"to "+(root.message.to_emails || []).join(", "); color:Theme.secondary; font.pixelSize:10; elide:Text.ElideRight }
                    }
                    MokaidLabel { text:Mail.date(root.message.received_at,true); font.pixelSize:10; color:Theme.secondary }
                    MokaidButton { iconName:"star"; implicitWidth:28; implicitHeight:28; quiet:true; contentItem:MokaidIcon { name:"star"; size:17; color:root.message.is_starred ? Theme.primary : Theme.secondary } enabled:root.controller.canManage&&!root.controller.mutating; Accessible.name:root.message.is_starred ? "Remove star" : "Star message"; onClicked:root.controller.act("star",!root.message.is_starred) }
                }
                MokaidLabel { Layout.fillWidth:true; text:root.message.subject || "No subject"; font.pixelSize:22; font.weight:Font.DemiBold; wrapMode:Text.Wrap; maximumLineCount:3; elide:Text.ElideRight }
                Rectangle {
                    visible:!!Mail.category(root.message); implicitHeight:25; implicitWidth:category.implicitWidth+18; radius:7; color:"#29203f"
                    MokaidLabel { id:category; anchors.centerIn:parent; text:Mail.category(root.message); color:Mail.color(root.message.ai_category); font.pixelSize:11 }
                }
                ColumnLayout {
                    visible:root.controller.detailLoading; Layout.fillWidth:true; spacing:12
                    Repeater { model:5; Rectangle { required property int index; Layout.fillWidth:index<4; Layout.preferredWidth:index===4 ? 160 : -1; Layout.preferredHeight:13; radius:4; color:Theme.control } }
                    MokaidLabel { text:"Loading message…"; font.pixelSize:11; color:Theme.muted }
                }
                RowLayout {
                    visible:!!root.message.hydration_error; Layout.fillWidth:true
                    MokaidLabel { Layout.fillWidth:true; text:root.message.hydration_error || ""; color:Theme.warning; font.pixelSize:12; wrapMode:Text.Wrap }
                    MokaidButton { text:"Retry"; quiet:true; enabled:!root.controller.detailLoading; onClicked:root.controller.select(root.controller.selectedId) }
                }
                Rectangle {
                    visible:!root.controller.detailLoading; Layout.fillWidth:true; implicitHeight:body.implicitHeight+40; radius:12; color:Theme.deep; border.color:Theme.border
                    TextEdit {
                        id:body; objectName:"mailMessageBody"
                        anchors.left:parent.left; anchors.right:parent.right; anchors.top:parent.top; anchors.margins:20
                        readOnly:true; selectByMouse:true; selectByKeyboard:true; wrapMode:TextEdit.Wrap; textFormat:TextEdit.RichText
                        text:root.message.safe_body || "<p>This message has no body.</p>"
                        color:Theme.text; selectedTextColor:"white"; selectionColor:Theme.selection; font.family:Theme.fontFamily; font.pixelSize:13
                        onLinkActivated:function(link){root.controller.openLink(link);}
                        Accessible.name:"Message body"
                    }
                }
                ColumnLayout {
                    Layout.fillWidth:true; visible:(root.message.attachments || []).length>0; spacing:8
                    MokaidLabel { text:"Attachments"; font.weight:Font.DemiBold; font.pixelSize:12 }
                    Repeater {
                        model:root.message.attachments || []
                        Rectangle {
                            id:attachment
                            required property var modelData
                            layer.enabled:true
                            Layout.fillWidth:true; implicitHeight:62; radius:10; color:Theme.deep; border.color:Theme.border
                            RowLayout {
                                anchors.fill:parent; anchors.margins:10; spacing:8
                                MokaidIcon { name:"file"; size:23; color:Theme.primary }
                                ColumnLayout { Layout.fillWidth:true; spacing:3
                                    MokaidLabel { Layout.fillWidth:true; text:attachment.modelData.filename || "Attachment"; font.pixelSize:12; elide:Text.ElideMiddle }
                                    MokaidLabel { text:Mail.size(attachment.modelData.size || 0); font.pixelSize:10; color:Theme.secondary }
                                }
                                MokaidButton { objectName:"mailViewAttachment_"+attachment.modelData.id; text:"View"; quiet:true; implicitHeight:34; enabled:root.controller.online; onClicked:root.controller.attachment(attachment.modelData.id,true) }
                                MokaidButton { objectName:"mailDownloadAttachment_"+attachment.modelData.id; iconName:"download"; quiet:true; implicitWidth:34; implicitHeight:34; enabled:root.controller.online; Accessible.name:"Download "+attachment.modelData.filename; onClicked:root.controller.attachment(attachment.modelData.id,false) }
                            }
                        }
                    }
                }
                MokaidLabel { visible:!root.controller.detailLoading&&!!root.message.safe_body; Layout.fillWidth:true; text:"External images and active content are omitted for privacy."; color:Theme.muted; font.pixelSize:10; wrapMode:Text.Wrap }
            }
        }
        Rectangle {
            visible:!!root.controller.selectedId; Layout.fillWidth:true; Layout.preferredHeight:66; radius:12; color:Theme.deep; border.color:Theme.border
            RowLayout {
                anchors.fill:parent; anchors.margins:10; spacing:12
                Rectangle { implicitWidth:35; implicitHeight:35; radius:18; color:"#31243f"; MokaidIcon { anchors.centerIn:parent; name:"reply"; color:"#d8c4ff"; size:18 } }
                AbstractButton { Layout.fillWidth:true; Layout.fillHeight:true; Accessible.name:"Write a reply"; contentItem:MokaidLabel { text:root.controller.hasDraft ? "Resume your draft…" : "Reply to "+(root.message.from_email || Mail.sender(root.message))+"…"; font.pixelSize:11; color:Theme.secondary; elide:Text.ElideRight } onClicked:root.replyRequested() }
                MokaidButton { objectName:"mailReplyButton"; text:root.controller.hasDraft ? "Resume" : "Reply"; iconName:"send"; highlighted:true; onClicked:root.replyRequested() }
            }
        }
    }
    ColumnLayout {
        anchors.centerIn:parent; width:Math.min(300,parent.width-40); spacing:14; visible:!root.controller.selectedId
        MokaidIcon { Layout.alignment:Qt.AlignHCenter; name:"mail"; size:36; color:Theme.muted }
        MokaidLabel { Layout.fillWidth:true; text:"Select a message"; horizontalAlignment:Text.AlignHCenter; font.pixelSize:20; font.weight:Font.DemiBold }
        MokaidLabel { Layout.fillWidth:true; text:"Read, reply and find attachments here."; horizontalAlignment:Text.AlignHCenter; color:Theme.secondary; wrapMode:Text.Wrap }
    }
    MokaidMenu {
        id:actions
        MokaidMenu.Entry { text:root.message.folder==="spam" ? "Not spam" : "Report spam"; enabled:root.controller.canManage&&!root.controller.mutating; onTriggered:root.controller.act("spam",root.message.folder!=="spam") }
        MokaidMenu.Entry { text:root.message.is_read ? "Mark unread" : "Mark read"; enabled:root.controller.canManage&&!root.controller.mutating; onTriggered:root.controller.act("read",!root.message.is_read) }
    }
}
