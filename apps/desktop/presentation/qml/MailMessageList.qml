pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "MailLogic.js" as Mail

Rectangle {
    id:root
    required property var controller
    property bool compact:false
    property bool connected:false
    signal selected(string id)
    signal connectRequested()
    color:Theme.surface; radius:14; border.color:Theme.border
    ColumnLayout {
        anchors.fill:parent; anchors.margins:3; spacing:2
        RowLayout {
            Layout.fillWidth:true; Layout.margins:10; spacing:8
            Rectangle {
                Layout.preferredWidth:root.width<380 ? 180 : 214; Layout.preferredHeight:36; radius:9; color:Theme.deep; border.color:Theme.border
                RowLayout {
                    anchors.fill:parent; anchors.margins:2; spacing:0
                    Repeater {
                        model:[{key:"all",name:"All"},{key:"unread",name:"Unread"},{key:"flagged",name:"Flagged"}]
                        AbstractButton {
                            id:filter
                            required property var modelData
                            Layout.fillWidth:true; Layout.fillHeight:true; hoverEnabled:true
                            objectName:"mailFilter_"+modelData.key; Accessible.name:modelData.name+" messages"
                            background:Rectangle { radius:7; color:root.controller.filter===filter.modelData.key ? "#6136aa" : filter.hovered ? Theme.hover : "transparent"; border.color:filter.visualFocus ? Theme.focusBorder : "transparent" }
                            contentItem:MokaidLabel { text:filter.modelData.name; horizontalAlignment:Text.AlignHCenter; font.pixelSize:11; color:root.controller.filter===filter.modelData.key ? "white" : Theme.secondary }
                            onClicked:root.controller.setFilter(modelData.key)
                        }
                    }
                }
            }
            Item { Layout.fillWidth:true }
            MokaidComboBox {
                objectName:"mailSort"; Layout.preferredWidth:root.width>420 ? 126 : 106; implicitHeight:36
                model:["Most recent","Oldest first","Sender","Subject"]
                currentIndex:["newest","oldest","sender","subject"].indexOf(root.controller.sort)
                onActivated:function(index){root.controller.setSort(["newest","oldest","sender","subject"][index]);}
                Accessible.name:"Sort messages"
            }
        }
        ListView {
            id:messages; objectName:"mailMessageList"
            Layout.fillWidth:true; Layout.fillHeight:true; clip:true; model:root.controller.messages; spacing:1
            currentIndex:root.controller.messages.findIndex(function(m){return m.id===root.controller.selectedId;})
            keyNavigationEnabled:true; highlightMoveDuration:0
            onCurrentIndexChanged:if(activeFocus && currentIndex>=0) root.selected(root.controller.messages[currentIndex].id)
            delegate:AbstractButton {
                id:row
                required property var modelData
                readonly property bool selected:modelData.id===root.controller.selectedId
                objectName:"mailMessage_"+modelData.id
                width:ListView.view.width; height:78; hoverEnabled:true
                Accessible.name:Mail.sender(modelData)+", "+(modelData.subject || "No subject")+(modelData.is_read ? "" : ", unread")
                background:Rectangle { radius:10; color:row.selected ? "#211831" : row.hovered ? Theme.hover : "transparent"; border.color:row.visualFocus ? Theme.focusBorder : row.selected ? "#8c4de1" : "transparent" }
                contentItem:RowLayout {
                    anchors.fill:parent; anchors.margins:10; spacing:10
                    Rectangle { implicitWidth:7; implicitHeight:7; radius:4; color:row.modelData.is_read ? "transparent" : "#9754fb"; Layout.alignment:Qt.AlignVCenter }
                    Rectangle {
                        Layout.preferredWidth:42; Layout.preferredHeight:42; radius:12; color:row.selected ? "#5b3793" : "#292439"
                        MokaidLabel { anchors.centerIn:parent; text:Mail.initials(row.modelData); font.pixelSize:16; font.weight:Font.DemiBold; color:"#e8dfff" }
                    }
                    ColumnLayout {
                        Layout.fillWidth:true; spacing:4
                        MokaidLabel { Layout.fillWidth:true; text:Mail.sender(row.modelData); font.pixelSize:12; font.weight:row.modelData.is_read ? Font.Medium : Font.DemiBold; elide:Text.ElideRight }
                        MokaidLabel { Layout.fillWidth:true; text:row.modelData.subject || "No subject"; color:row.modelData.is_read ? Theme.secondary : Theme.text; font.pixelSize:11; elide:Text.ElideRight }
                        MokaidLabel { Layout.fillWidth:true; text:row.modelData.snippet || ""; color:Theme.muted; font.pixelSize:10; elide:Text.ElideRight }
                    }
                    ColumnLayout {
                        Layout.preferredWidth:root.width>=400 ? 94 : 52; spacing:2
                        MokaidLabel { Layout.alignment:Qt.AlignRight; text:Mail.date(row.modelData.received_at,false); color:Theme.secondary; font.pixelSize:10 }
                        Rectangle {
                            visible:root.width>=400&&!!Mail.category(row.modelData); Layout.alignment:Qt.AlignRight
                            implicitWidth:tag.implicitWidth+12; implicitHeight:18; radius:5; color:"#282034"
                            MokaidLabel { id:tag; anchors.centerIn:parent; text:Mail.category(row.modelData); font.pixelSize:9; color:Mail.color(row.modelData.ai_category) }
                        }
                        RowLayout {
                            Layout.alignment:Qt.AlignRight; spacing:2
                            MokaidIcon { visible:!!row.modelData.has_attachments; name:"attachment"; size:15; color:Theme.secondary }
                            MokaidButton { objectName:"mailStar_"+row.modelData.id; implicitWidth:28; implicitHeight:27; quiet:true; iconName:"star"; contentItem:MokaidIcon { name:"star"; size:17; color:row.modelData.is_starred ? Theme.primary : Theme.secondary } enabled:root.controller.canManage&&!root.controller.mutating; Accessible.name:row.modelData.is_starred ? "Remove star" : "Star message"; onClicked:root.controller.act("star",!row.modelData.is_starred,row.modelData.id) }
                        }
                    }
                }
                onClicked:root.selected(modelData.id)
                Rectangle { visible:!row.selected; anchors.left:parent.left; anchors.right:parent.right; anchors.bottom:parent.bottom; anchors.leftMargin:10; anchors.rightMargin:10; height:1; color:Theme.divider }
            }
            footer:MokaidButton { visible:root.controller.hasMore; width:messages.width; text:root.controller.busy ? "Loading…" : "Load more messages"; quiet:true; enabled:!root.controller.busy; onClicked:root.controller.loadMore() }
            ScrollBar.vertical:ScrollBar {}
            ColumnLayout {
                anchors.centerIn:parent; width:Math.max(120,parent.width-48); spacing:12
                visible:!root.controller.messages.length
                MokaidIcon { Layout.alignment:Qt.AlignHCenter; name:"mail"; size:32; color:Theme.primary }
                MokaidLabel { Layout.fillWidth:true; text:root.controller.busy ? "Loading your mail…" : root.connected ? "No messages here" : "Connect your first mailbox"; horizontalAlignment:Text.AlignHCenter; font.pixelSize:17; font.weight:Font.DemiBold; wrapMode:Text.Wrap }
                MokaidLabel { Layout.fillWidth:true; text:root.controller.busy ? "" : root.connected ? "Choose another folder, clear your filters, or sync your mail." : "Connect Gmail or an IMAP mailbox to read and send mail here."; horizontalAlignment:Text.AlignHCenter; color:Theme.secondary; wrapMode:Text.Wrap; font.pixelSize:12 }
                MokaidButton { objectName:"emptyConnectMailbox"; Layout.alignment:Qt.AlignHCenter; visible:!root.connected&&!root.controller.busy; text:"Connect mailbox"; highlighted:true; onClicked:root.connectRequested() }
            }
        }
    }
}
