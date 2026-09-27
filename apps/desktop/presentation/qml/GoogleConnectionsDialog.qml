pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

MokaidDialog {
    id:root
    required property var controller
    property string filterKey:""
    readonly property var shownServices:controller.services.filter(function(s){return !root.filterKey || s.key===root.filterKey;})
    readonly property bool working:controller.pending || controller.submitting
    parent:Overlay.overlay; anchors.centerIn:parent
    width:Math.min(710,parent ? parent.width-32 : 710)
    height:Math.min(implicitHeight,parent ? parent.height-32 : implicitHeight)
    modal:true; focus:true
    closePolicy:working ? Popup.NoAutoClose : Popup.CloseOnEscape
    title:controller.pending ? "Connect "+controller.providerName : "Google accounts and services"
    function start(providerKey,connectNow) {
        filterKey=providerKey || "";
        controller.clearFeedback(); controller.refresh(); open();
        if(connectNow && filterKey) controller.start(filterKey);
    }
    Connections {
        target:root.controller
        function onContextReset(){root.close(); root.filterKey="";}
    }
    contentItem:ScrollView {
        objectName:"googleServicesScroll"
        ScrollBar.vertical.policy:contentHeight>availableHeight ? ScrollBar.AlwaysOn : ScrollBar.AsNeeded
        implicitHeight:Math.min(content.implicitHeight,540); contentWidth:availableWidth; clip:true
        ColumnLayout {
            id:content; width:parent.width; spacing:12
            MokaidLabel {
                visible:!root.controller.pending; Layout.fillWidth:true; wrapMode:Text.Wrap; color:Theme.secondary
                text:"Choose a service, then select your Google account. Each connection requests access to that service. You can connect multiple accounts."
            }
            MokaidLabel { visible:root.controller.message.length>0; Layout.fillWidth:true; text:root.controller.message; color:root.controller.needsAttention ? Theme.warning : Theme.success; wrapMode:Text.Wrap }
            MokaidLabel { visible:root.controller.error.length>0; Layout.fillWidth:true; text:root.controller.error; color:Theme.warning; wrapMode:Text.Wrap; Accessible.role:Accessible.AlertMessage }
            ColumnLayout {
                visible:root.controller.pending; Layout.fillWidth:true; spacing:14
                BusyIndicator { running:root.controller.pending; Layout.alignment:Qt.AlignHCenter; Layout.preferredWidth:36; Layout.preferredHeight:36 }
                MokaidLabel { Layout.fillWidth:true; text:"Finish connecting in your browser"; horizontalAlignment:Text.AlignHCenter; font.weight:Font.DemiBold }
                MokaidLabel { Layout.fillWidth:true; text:"Choose an account and allow access to "+root.controller.providerName+". Mokaid confirms the connection automatically."; color:Theme.secondary; horizontalAlignment:Text.AlignHCenter; wrapMode:Text.Wrap }
                RowLayout {
                    Layout.alignment:Qt.AlignHCenter; spacing:8
                    MokaidButton { objectName:"googleReopenBrowser"; text:"Reopen browser"; enabled:!root.controller.submitting; onClicked:root.controller.reopenBrowser() }
                    MokaidButton { objectName:"googleCheckConnection"; text:"Check connection"; quiet:true; enabled:!root.controller.submitting; onClicked:root.controller.check() }
                }
                GoogleSignInHelp { Layout.fillWidth:true; objectName:"googleSignInHelp" }
            }
            ColumnLayout {
                visible:!root.controller.pending; Layout.fillWidth:true; spacing:10
                Repeater {
                    model:root.shownServices
                    Rectangle {
                        id:service
                        required property var modelData
                        readonly property var accounts:root.controller.connections.filter(function(c){return c.provider_key===service.modelData.key;})
                        Layout.fillWidth:true; implicitHeight:serviceContent.implicitHeight+24; radius:12; color:Theme.surface; border.color:Theme.border
                        ColumnLayout {
                            id:serviceContent; anchors.left:parent.left; anchors.right:parent.right; anchors.top:parent.top; anchors.margins:12; spacing:8
                            RowLayout {
                                Layout.fillWidth:true; spacing:10
                                ColumnLayout {
                                    Layout.fillWidth:true; spacing:3
                                    MokaidLabel { Layout.fillWidth:true; text:service.modelData.name; font.weight:Font.DemiBold; elide:Text.ElideRight }
                                    MokaidLabel { Layout.fillWidth:true; text:service.modelData.description; font.pixelSize:12; color:Theme.secondary; wrapMode:Text.Wrap }
                                }
                                MokaidButton {
                                    objectName:"googleConnect_"+service.modelData.key
                                    text:service.accounts.some(function(c){return c.status==="connected";}) ? "Add account" : "Connect"
                                    enabled:root.controller.online && !root.working; highlighted:true
                                    Accessible.name:"Connect "+service.modelData.name
                                    onClicked:root.controller.start(service.modelData.key)
                                }
                            }
                            Repeater {
                                model:service.accounts
                                RowLayout {
                                    id:account
                                    required property var modelData
                                    Layout.fillWidth:true; spacing:8
                                    MokaidLabel { Layout.fillWidth:true; text:account.modelData.connected_account || "Google account"; font.pixelSize:12; color:Theme.secondary; elide:Text.ElideRight }
                                    MokaidLabel { text:account.modelData.status==="connected" ? "Connected" : "Needs reconnection"; font.pixelSize:11; color:account.modelData.status==="connected" ? Theme.success : Theme.warning }
                                    MokaidButton { text:"Reconnect"; quiet:true; enabled:root.controller.online && !root.working; onClicked:root.controller.start(service.modelData.key) }
                                }
                            }
                        }
                    }
                }
                MokaidButton { objectName:"googleShowAllServices"; visible:root.filterKey.length>0; text:"All Google services"; quiet:true; onClicked:root.filterKey="" }
            }
            MokaidLabel { visible:root.controller.submitting && !root.controller.pending; Layout.fillWidth:true; text:"Opening secure Google sign-in…"; wrapMode:Text.Wrap; color:Theme.secondary }
            MokaidLabel { visible:!root.controller.online; Layout.fillWidth:true; text:"Reconnect to the internet to connect Google services."; wrapMode:Text.Wrap; color:Theme.warning }
        }
    }
    footer:RowLayout {
        MokaidButton {
            objectName:"googleConnectionClose"; Layout.leftMargin:24; Layout.topMargin:12; Layout.bottomMargin:24
            text:root.controller.pending ? "Cancel sign-in" : "Done"; enabled:!root.controller.submitting
            onClicked:{if(root.controller.pending) root.controller.cancel(); else root.close();}
        }
        Item {Layout.fillWidth:true}
        MokaidButton { Layout.rightMargin:24; Layout.topMargin:12; Layout.bottomMargin:24; visible:!root.controller.pending; text:"Refresh connections"; quiet:true; enabled:!root.controller.refreshing && !root.controller.submitting && root.controller.online; onClicked:root.controller.refresh() }
    }
}
