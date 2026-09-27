pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id:root
    required property var controller
    required property var downloads
    required property var accounts
    signal connectRequested()
    signal manageRequested()
    property bool showReader:false
    readonly property bool compact:width<790
    readonly property bool foldersVisible:width>=1110
    function compose(reply) { controller.compose(reply); showReader=true; }
    Connections { target:root.controller; function onContextReset(){root.showReader=false;} }
    ColumnLayout {
        anchors.fill:parent; anchors.topMargin:4; anchors.bottomMargin:8; spacing:16
        RowLayout {
            Layout.fillWidth:true; spacing:10
            ColumnLayout { Layout.fillWidth:true; spacing:5
                MokaidLabel { text:"Mail"; font.pixelSize:28; font.weight:Font.DemiBold }
                MokaidLabel { Layout.fillWidth:true; text:"All your inboxes, together in one workspace."; color:Theme.secondary; font.pixelSize:12; elide:Text.ElideRight }
            }
            MokaidButton { objectName:"mailSyncButton"; iconName:"refresh"; text:root.width>1050 ? "Sync mail" : ""; quiet:true; enabled:root.accounts.online&&!root.accounts.syncing&&root.accounts.accounts.length>0; Accessible.name:"Sync mail"; onClicked:{root.accounts.synchronize();root.controller.refresh();} }
            MokaidComboBox { objectName:"mailAccountSelector"; Layout.preferredWidth:root.width<900 ? 156 : 200; model:[{id:"",email_address:"All mailboxes"}].concat(root.accounts.accounts.map(function(a){return a;})); textRole:"email_address"; valueRole:"id"; currentIndex:Math.max(0,model.findIndex(function(a){return a.id===root.accounts.selectedId;})); onActivated:root.accounts.select(currentValue); Accessible.name:"Mailbox filter" }
            MokaidButton { objectName:"featurePrimaryButton"; text:root.width<900 ? "Connect" : "Connect mailbox"; iconName:"plus"; highlighted:true; enabled:root.accounts.online&&!root.accounts.submitting; onClicked:root.connectRequested() }
            MokaidButton { objectName:"mailManageAccounts"; iconName:"more"; quiet:true; implicitWidth:30; Accessible.name:"Manage mailboxes"; onClicked:root.manageRequested() }
        }
        RowLayout {
            visible:!root.foldersVisible; Layout.fillWidth:true
            MokaidButton { objectName:"mailCompactCompose"; text:root.controller.hasDraft ? "Resume draft" : "Compose"; iconName:"pen"; highlighted:true; onClicked:root.compose(false) }
            MokaidComboBox { Layout.preferredWidth:180; model:[{key:"inbox",name:"Inbox"},{key:"starred",name:"Starred"},{key:"sent",name:"Sent"},{key:"drafts",name:"Drafts"},{key:"spam",name:"Spam"},{key:"trash",name:"Trash"},{key:"all",name:"All mail"}]; textRole:"name"; valueRole:"key"; currentIndex:indexOfValue(root.controller.folder); onActivated:{root.controller.setFolder(currentValue);root.showReader=false;} Accessible.name:"Mail folder" }
            Item { Layout.fillWidth:true }
            MokaidLabel { visible:root.controller.busy; text:"Loading…"; color:Theme.muted; font.pixelSize:11 }
        }
        RowLayout {
            visible:!!root.controller.error || !!root.controller.notice || !!root.accounts.error || !!root.accounts.message || !!root.downloads.error || !!root.downloads.status || !root.controller.online
            Layout.fillWidth:true; spacing:10
            MokaidLabel { Layout.fillWidth:true; text:root.controller.error || root.accounts.error || root.downloads.error || root.downloads.status || root.controller.notice || root.accounts.message || "You're offline. Reconnect to load mail."; color:root.controller.error || root.accounts.error || root.downloads.error ? Theme.warning : Theme.secondary; font.pixelSize:12; wrapMode:Text.Wrap }
            MokaidButton { visible:root.downloads.busy; text:"Cancel download"; quiet:true; onClicked:root.downloads.cancel() }
            MokaidButton { visible:!!root.controller.error&&!root.controller.composing; text:"Retry"; quiet:true; enabled:root.controller.online&&!root.controller.busy; onClicked:root.controller.refresh() }
        }
        RowLayout {
            Layout.fillWidth:true; Layout.fillHeight:true; spacing:12
            MailFolders { objectName:"mailFolders"; controller:root.controller; visible:root.foldersVisible; Layout.preferredWidth:174; Layout.fillHeight:true; onComposeRequested:root.compose(false) }
            MailMessageList {
                objectName:"mailMessagesPanel"; controller:root.controller; connected:root.accounts.accounts.length>0; compact:root.compact
                visible:!root.compact || (!root.showReader&&!root.controller.composing)
                Layout.fillHeight:true; Layout.fillWidth:root.compact; Layout.preferredWidth:root.compact ? -1 : Math.max(330,Math.min(450,(root.width-(root.foldersVisible?186:0))*0.43))
                onSelected:function(id){root.controller.closeComposer();root.controller.select(id);root.showReader=true;}
                onConnectRequested:root.connectRequested()
            }
            Item {
                Layout.fillWidth:true; Layout.fillHeight:true; visible:!root.compact || root.showReader || root.controller.composing
                MailReader { objectName:"mailReaderPanel"; anchors.fill:parent; visible:!root.controller.composing; controller:root.controller; compact:root.compact; onReplyRequested:root.compose(true); onBackRequested:root.showReader=false }
                MailComposer { objectName:"mailComposerPanel"; anchors.fill:parent; visible:root.controller.composing; controller:root.controller; accounts:root.accounts }
            }
        }
    }
}
