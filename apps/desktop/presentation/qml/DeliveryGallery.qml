pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: root
    property var files: []
    property bool showHeading: true
    readonly property var imageIndices: {
        const indices = []
        for (let i = 0; i < files.length; ++i)
            if (preview.describe(files[i]).kind === "image") indices.push(i)
        return indices
    }
    readonly property var documentIndices: {
        const indices = []
        for (let i = 0; i < files.length; ++i)
            if (preview.describe(files[i]).kind !== "image") indices.push(i)
        return indices
    }
    visible: files.length > 0
    spacing: 12
    MokaidLabel {
        Layout.fillWidth: true
        visible: root.showHeading
        text: root.files.length === 1 ? "Deliverable" : "Deliverables · " + root.files.length
        font.pixelSize: 15; font.weight: Font.DemiBold
    }
    GridLayout {
        Layout.fillWidth: true
        visible: root.imageIndices.length > 0
        columns: root.width >= 400 && root.imageIndices.length > 1 ? 2 : 1
        columnSpacing: 12; rowSpacing: 12
        Repeater {
            model: root.imageIndices
            DeliveryCard {
                required property int modelData
                Layout.fillWidth: true
                Layout.preferredWidth: 1
                file: root.files[modelData] || ({})
                onClicked: preview.openCollection(root.files, modelData)
            }
        }
    }
    ColumnLayout {
        Layout.fillWidth: true; spacing: 2
        visible: root.documentIndices.length > 0
        Repeater {
            model: root.documentIndices
            DeliveryCard {
                required property int modelData
                Layout.fillWidth: true
                file: root.files[modelData] || ({})
                onClicked: preview.openCollection(root.files, modelData)
            }
        }
    }
}
