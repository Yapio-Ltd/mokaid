pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "FeatureLogic.js" as Logic

MokaidDialog {
    id:root
    required property var controller
    signal connectRequested(var account)
    property var removal: ({})
    parent:Overlay.overlay; anchors.centerIn:parent
    width:Math.min(680,parent ? parent.width-32 : 680)
    height:Math.min(implicitHeight,parent ? parent.height-32 : implicitHeight)
    modal:true; focus:true; title:"Connected mailboxes"; standardButtons:Dialog.Close
    onOpened:controller.refresh()
    Connections { target:root.controller; function onContextReset(){root.close(); removalDialog.close();} }
    contentItem:ScrollView {
        implicitHeight:Math.min(list.implicitHeight,500); contentWidth:availableWidth; clip:true
        ColumnLayout {
            id:list; width:parent.width; spacing:12
            MokaidLabel { visible:root.controller.accounts.length===0; Layout.fillWidth:true; text:root.controller.refreshing ? "Loading your mailboxes…" : "Connect your first mailbox to bring your mail into this workspace."; wrapMode:Text.Wrap; color:Theme.secondary }
            Repeater {
                model:root.controller.accounts
                Rectangle {
                    id:row
                    required property var modelData
                    Layout.fillWidth:true; implicitHeight:accountContent.implicitHeight+28
                    radius:12; color:Theme.surface; border.color:Theme.border
                    ColumnLayout {
                        id:accountContent; anchors.left:parent.left; anchors.right:parent.right; anchors.top:parent.top; anchors.margins:14; spacing:8
                        MokaidLabel { Layout.fillWidth:true; text:row.modelData.email_address || "Mailbox"; font.weight:Font.DemiBold; elide:Text.ElideRight }
                        MokaidLabel {
                            Layout.fillWidth:true; text:(row.modelData.provider==="gmail" ? "Google" : row.modelData.provider==="microsoft" ? "Microsoft" : "IMAP / SMTP")+" · "+(row.modelData.status==="error" ? "Needs attention" : Logic.human(row.modelData.status || "connected")); font.pixelSize:12; color:row.modelData.status==="error" ? Theme.warning : Theme.secondary; wrapMode:Text.Wrap
                        }
                        MokaidLabel { Layout.fillWidth:true; text:row.modelData.error_message || (row.modelData.last_sync_at ? "Last synchronized "+Logic.date(row.modelData.last_sync_at,true) : "First synchronization pending"); font.pixelSize:12; color:row.modelData.error_message ? Theme.warning : Theme.muted; wrapMode:Text.Wrap }
                        Flow {
                            Layout.fillWidth:true; spacing:8
                            MokaidButton { text:"Sync"; quiet:true; enabled:root.controller.online && !root.controller.syncing; onClicked:root.controller.synchronize(row.modelData.id) }
                            MokaidButton { visible:row.modelData.provider==="imap" || row.modelData.provider==="gmail"; text:"Reconnect"; quiet:true; enabled:root.controller.online && !root.controller.submitting && !root.controller.oauthPending; onClicked:{root.close(); if(row.modelData.provider==="gmail") {root.connectRequested({}); root.controller.connectGoogle();} else root.connectRequested(row.modelData);} }
                            MokaidButton { text:"Disconnect"; quiet:true; enabled:root.controller.online && !root.controller.submitting; onClicked:{root.removal=row.modelData; removalDialog.open();} }
                        }
                    }
                }
            }
            MokaidLabel { visible:root.controller.error.length>0; Layout.fillWidth:true; text:root.controller.error; color:Theme.warning; wrapMode:Text.Wrap }
            MokaidButton { Layout.fillWidth:true; text:"Add another mailbox"; highlighted:true; enabled:root.controller.online && !root.controller.submitting; onClicked:{root.close(); root.connectRequested({});} }
        }
    }
    MokaidDialog {
        id:removalDialog; parent:Overlay.overlay; anchors.centerIn:parent
        width:Math.min(480,parent ? parent.width-32 : 480); implicitHeight:280; modal:true; title:"Disconnect mailbox?"
        standardButtons:Dialog.Cancel | Dialog.Ok
        contentItem:Item {
            implicitHeight:removalText.implicitHeight
            MokaidLabel { id:removalText; width:removalDialog.availableWidth; text:"Disconnect "+(root.removal.email_address || "this mailbox")+" from this workspace? Its synchronized messages and mailbox rules will be removed from Mokaid. Your email provider keeps the original messages."; wrapMode:Text.Wrap; color:Theme.secondary }
        }
        onAccepted:root.controller.disconnectAccount(root.removal.id)
    }
}
