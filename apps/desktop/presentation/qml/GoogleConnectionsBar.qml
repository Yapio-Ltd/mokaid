pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts

Rectangle {
    id:root
    required property var controller
    property string providerKey:""
    readonly property var matching:controller.connections.filter(function(c){return (!root.providerKey || c.provider_key===root.providerKey) && c.status==="connected";})
    readonly property string serviceName:providerKey==="google_calendar" ? "Google Calendar" : providerKey==="google_drive" ? "Google Drive" : "Google services"
    signal manageRequested(string providerKey,bool connectNow)
    implicitHeight:content.implicitHeight+24
    color:Theme.surface; radius:12; border.color:Theme.border
    ColumnLayout {
        id:content; anchors.left:parent.left; anchors.right:parent.right; anchors.top:parent.top; anchors.margins:12; spacing:6
        RowLayout {
            Layout.fillWidth:true; spacing:12
            MokaidIcon { name:root.providerKey==="google_calendar" ? "calendar" : root.providerKey==="google_drive" ? "folder" : "integrations"; size:22; color:Theme.primary }
            ColumnLayout {
                Layout.fillWidth:true; spacing:3
                MokaidLabel { Layout.fillWidth:true; text:root.serviceName; font.weight:Font.DemiBold; elide:Text.ElideRight }
                MokaidLabel {
                    Layout.fillWidth:true; font.pixelSize:12; color:Theme.secondary; wrapMode:Text.Wrap
                    text:root.controller.refreshing && !root.matching.length ? "Checking connections…" : root.matching.length ? root.matching.map(function(c){return c.connected_account+(root.providerKey ? "" : " · "+c.provider_name);}).join("  •  ") : root.providerKey ? "Connect your Google account securely in your browser." : "Gmail, Calendar, Drive, Docs, Sheets and Meet. Choose the services you need."
                    maximumLineCount:2; elide:Text.ElideRight
                }
            }
            MokaidButton {
                objectName:"googleServiceConnectButton"; text:root.matching.length ? "Manage" : root.providerKey ? "Connect" : "Google accounts"
                enabled:root.controller.online && !root.controller.submitting; highlighted:!root.matching.length
                Accessible.name:(root.matching.length ? "Manage " : "Connect ")+root.serviceName
                onClicked:root.manageRequested(root.providerKey,!!root.providerKey && !root.matching.length)
            }
        }
        MokaidLabel {
            visible:!!root.providerKey; Layout.fillWidth:true; font.pixelSize:11; color:Theme.secondary; wrapMode:Text.Wrap
            text:root.providerKey==="google_calendar" ? "Google events are available to authorized agents. They are not imported into this calendar." : "Google Drive files are available to authorized agents. They are not imported into workspace files."
        }
        MokaidLabel { visible:root.controller.error.length>0; Layout.fillWidth:true; text:root.controller.error; font.pixelSize:12; wrapMode:Text.Wrap; color:Theme.warning }
        MokaidLabel { visible:root.controller.message.length>0; Layout.fillWidth:true; text:root.controller.message; font.pixelSize:12; wrapMode:Text.Wrap; color:Theme.secondary }
    }
}
