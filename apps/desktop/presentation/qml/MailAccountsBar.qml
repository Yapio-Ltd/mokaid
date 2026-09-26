pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "FeatureLogic.js" as Logic

ColumnLayout {
    id:root
    required property var controller
    signal manageRequested()
    readonly property int problemCount:controller.accounts.filter(function(a){return a.status==="error" || !!a.error_message;}).length
    spacing:8
    RowLayout {
        Layout.fillWidth:true; spacing:10
        MokaidComboBox {
            objectName:"mailAccountSelector"; Layout.fillWidth:true; Layout.maximumWidth:340
            model:["All mailboxes"].concat(root.controller.accounts.map(function(a){return a.email_address;}))
            currentIndex:root.controller.selectedId.length ? root.controller.accounts.findIndex(function(a){return a.id===root.controller.selectedId;})+1 : 0
            enabled:root.controller.accounts.length>0
            onActivated:function(index){root.controller.select(index===0 ? "" : root.controller.accounts[index-1].id);}
            Accessible.name:"Filter by mailbox"
        }
        Item {Layout.fillWidth:true}
        MokaidButton { objectName:"mailSyncButton"; text:root.controller.syncing ? "Queuing…" : "Sync mail"; iconName:"refresh"; quiet:true; enabled:root.controller.online && !root.controller.syncing && root.controller.accounts.length>0; onClicked:root.controller.synchronize() }
        MokaidButton { objectName:"mailManageButton"; text:"Mailboxes ("+root.controller.accounts.length+")"; onClicked:root.manageRequested() }
    }
    MokaidLabel {
        Layout.fillWidth:true; visible:root.controller.selectedId.length>0; font.pixelSize:12; wrapMode:Text.Wrap
        readonly property var account:root.controller.selectedAccount
        text:account.error_message || (account.last_sync_at ? "Last synchronized "+Logic.date(account.last_sync_at,true) : "First synchronization pending")
        color:account.error_message ? Theme.warning : Theme.secondary
    }
    MokaidLabel { visible:root.problemCount>0 && !root.controller.selectedId.length; Layout.fillWidth:true; text:root.problemCount+(root.problemCount===1 ? " mailbox needs attention. Open Mailboxes to reconnect it." : " mailboxes need attention. Open Mailboxes to reconnect them."); color:Theme.warning; wrapMode:Text.Wrap; font.pixelSize:12 }
    MokaidLabel { visible:root.controller.error.length>0; Layout.fillWidth:true; text:root.controller.error; color:Theme.warning; wrapMode:Text.Wrap; font.pixelSize:12 }
    MokaidLabel { visible:root.controller.message.length>0 && !root.controller.oauthPending; Layout.fillWidth:true; text:root.controller.message; color:Theme.secondary; wrapMode:Text.Wrap; font.pixelSize:12 }
}
