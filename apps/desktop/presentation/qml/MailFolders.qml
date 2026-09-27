pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id:root
    required property var controller
    signal composeRequested()
    readonly property var destinations:[{key:"inbox",name:"Inbox",icon:"inbox"},{key:"starred",name:"Starred",icon:"star"},{key:"sent",name:"Sent",icon:"send"},{key:"drafts",name:"Drafts",icon:"pen"},{key:"spam",name:"Spam",icon:"alert"},{key:"trash",name:"Trash",icon:"trash"},{key:"all",name:"All mail",icon:"mail"}]
    function count(key) { const row=controller.folders.find(function(f){return f.key===key;}); return row ? (key==="inbox" ? row.unread_count : row.count) : 0; }
    color:Theme.surface; radius:14; border.color:Theme.border
    ColumnLayout {
        anchors.fill:parent; anchors.margins:10; spacing:14
        MokaidButton { objectName:"mailComposeButton"; Layout.fillWidth:true; Layout.preferredHeight:50; highlighted:true; iconName:"pen"; text:root.controller.hasDraft ? "Resume draft" : "Compose"; onClicked:root.composeRequested() }
        ColumnLayout {
            Layout.fillWidth:true; spacing:3
            Repeater {
                model:root.destinations
                AbstractButton {
                    id:folder
                    required property var modelData
                    readonly property bool selected:root.controller.folder===modelData.key && !root.controller.label
                    Layout.fillWidth:true; implicitHeight:36; hoverEnabled:true
                    Accessible.name:modelData.name
                    background:Rectangle { radius:9; color:folder.selected ? "#302047" : folder.hovered ? Theme.hover : "transparent"; border.color:folder.visualFocus ? Theme.focusBorder : "transparent" }
                    contentItem:RowLayout {
                        anchors.fill:parent; anchors.leftMargin:8; anchors.rightMargin:8; spacing:12
                        MokaidIcon { name:folder.modelData.icon; size:18; color:folder.selected ? "#e7daff" : Theme.secondary }
                        MokaidLabel { Layout.fillWidth:true; text:folder.modelData.name; color:folder.selected ? Theme.text : Theme.secondary; font.pixelSize:12 }
                        Rectangle {
                            visible:root.count(folder.modelData.key)>0; implicitWidth:Math.max(21,countLabel.implicitWidth+10); implicitHeight:20; radius:7; color:folder.selected ? Theme.primary : "#202034"
                            MokaidLabel { id:countLabel; anchors.centerIn:parent; text:root.count(folder.modelData.key); font.pixelSize:11; color:folder.selected ? "white" : Theme.secondary }
                        }
                    }
                    onClicked:{if(modelData.key==="drafts" && root.controller.hasDraft) root.composeRequested(); else root.controller.setFolder(modelData.key);}
                }
            }
        }
        MokaidLabel { Layout.topMargin:12; Layout.leftMargin:5; text:"Labels"; font.weight:Font.DemiBold; font.pixelSize:13 }
        ListView {
            Layout.fillWidth:true; Layout.fillHeight:true; model:root.controller.labels; spacing:5; clip:true
            delegate:AbstractButton {
                id:label
                required property var modelData
                required property int index
                width:ListView.view.width; height:33; hoverEnabled:true
                Accessible.name:"Filter label "+modelData.name
                background:Rectangle { radius:8; color:root.controller.label===label.modelData.name ? Theme.selected : label.hovered ? Theme.hover : "transparent"; border.color:label.visualFocus ? Theme.focusBorder : "transparent" }
                contentItem:RowLayout {
                    anchors.fill:parent; anchors.leftMargin:8; anchors.rightMargin:8; spacing:12
                    Rectangle { implicitWidth:12; implicitHeight:12; radius:3; color:["#dc5075","#19b773","#4c90ec","#9457ed","#eaaa46","#ca66bb"][label.index%6] }
                    MokaidLabel { Layout.fillWidth:true; text:label.modelData.name; color:Theme.secondary; font.pixelSize:12; elide:Text.ElideRight }
                    MokaidLabel { text:label.modelData.count || ""; color:Theme.secondary; font.pixelSize:11 }
                }
                onClicked:root.controller.setLabel(modelData.name)
            }
            MokaidLabel { visible:!root.controller.labels.length; width:parent.width-10; x:5; text:"Your synced labels appear here."; font.pixelSize:11; color:Theme.muted; wrapMode:Text.Wrap }
            ScrollBar.vertical:ScrollBar {}
        }
    }
}
