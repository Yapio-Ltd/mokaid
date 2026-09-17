pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

AbstractButton {
    id: root
    required property var file
    property bool compact: false
    readonly property var effectiveFile: file || ({})
    readonly property var format: preview.describe(effectiveFile)
    readonly property bool imageFile: format.kind === "image"
    readonly property string filename: effectiveFile.name || effectiveFile.filename || "Untitled file"
    readonly property string thumbnail: {
        preview.thumbnailRevision
        return imageFile && visible ? preview.thumbnailUrl(effectiveFile) : ""
    }
    readonly property string thumbnailStatus: {
        preview.thumbnailRevision
        return imageFile && visible ? preview.thumbnailState(effectiveFile) : "unavailable"
    }
    readonly property string fileIcon: format.kind === "image" ? "image"
        : format.kind === "video" ? "play" : format.kind === "audio" ? "headphones"
        : format.kind === "html" ? "code" : format.label === "Spreadsheet" ? "table" : "file"
    readonly property string metadata: format.label + (format.sizeLabel ? " · " + format.sizeLabel : "")
    objectName: "deliveryCard_" + (effectiveFile.id || effectiveFile.drive_item_id || "")
    implicitHeight: imageFile && !compact ? Math.min(250, Math.max(150, width * .68)) + 58 : 68
    enabled: !!(effectiveFile.id || effectiveFile.drive_item_id)
    hoverEnabled: true
    activeFocusOnTab: true
    padding: 0
    Accessible.name: "Open " + filename
    Accessible.description: metadata
    Keys.onReturnPressed: clicked()
    Keys.onEnterPressed: clicked()
    background: Rectangle {
        radius: 10
        color: root.down ? Theme.selected : root.hovered ? Theme.controlHover : "transparent"
        border.color: root.visualFocus ? Theme.focusBorder : "transparent"
        border.width: root.visualFocus ? 2 : 0
    }
    contentItem: Item {
        ColumnLayout {
            anchors.fill: parent
            spacing: 0
            Rectangle {
                Layout.fillWidth: true; Layout.fillHeight: true
                visible: root.imageFile && !root.compact
                color: Theme.deep; radius: 10
                Image {
                    id: imagePreview
                    objectName: "deliveryThumbnail"
                    anchors.fill: parent; anchors.margins: 4
                    source: root.thumbnail
                    asynchronous: true
                    sourceSize.width: 800; sourceSize.height: 600
                    fillMode: Image.PreserveAspectFit
                }
                ColumnLayout {
                    anchors.centerIn: parent; spacing: 10
                    visible: imagePreview.status !== Image.Ready
                    MokaidIcon { name: "image"; size: 28; color: Theme.secondary; Layout.alignment: Qt.AlignHCenter }
                    MokaidLabel { text: root.thumbnailStatus === "loading" || imagePreview.status === Image.Loading ? "Loading preview…" : "Open image"; color: Theme.secondary; font.pixelSize: 12 }
                }
            }
            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: root.imageFile && !root.compact ? 58 : 68
                Layout.leftMargin: root.imageFile && !root.compact ? 2 : 8
                Layout.rightMargin: 8
                spacing: 12
                Rectangle {
                    visible: !root.imageFile || root.compact
                    Layout.preferredWidth: 44; Layout.preferredHeight: 44
                    radius: 8; color: Theme.raised
                    Image {
                        anchors.fill: parent; anchors.margins: 2
                        source: root.compact ? root.thumbnail : ""
                        asynchronous: true; sourceSize.width: 100; sourceSize.height: 100
                        fillMode: Image.PreserveAspectFit
                    }
                    MokaidIcon { anchors.centerIn: parent; visible: !root.thumbnail; name: root.fileIcon; size: 22; color: Theme.secondary }
                }
                ColumnLayout {
                    Layout.fillWidth: true; spacing: 4
                    MokaidLabel { Layout.fillWidth: true; text: root.filename; font.pixelSize: 13; font.weight: Font.DemiBold; elide: Text.ElideMiddle }
                    MokaidLabel { Layout.fillWidth: true; text: root.metadata; color: Theme.secondary; font.pixelSize: 11; elide: Text.ElideRight }
                }
                MokaidIcon { name: "chevron-right"; size: 16; color: root.hovered || root.visualFocus ? Theme.text : Theme.muted }
            }
        }
    }
    ToolTip.visible: hovered
    ToolTip.text: filename
    ToolTip.delay: 700
}
