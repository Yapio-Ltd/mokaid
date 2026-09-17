import QtQuick
import QtQuick.Layouts

Rectangle {
    id: root
    property string iconName: "members"
    property string value: "0"
    property string label: ""
    property color accent: Theme.primary
    implicitWidth: 128; implicitHeight: 102; radius: 12
    border.color: Theme.border
    gradient: Gradient {
        GradientStop { position: 0; color: "#ee171726" }
        GradientStop { position: 1; color: "#ef10121e" }
    }
    Accessible.role: Accessible.StaticText
    Accessible.name: value + " " + label
    ColumnLayout {
        anchors.fill: parent; anchors.margins: 15
        spacing: 9
        RowLayout {
            Layout.fillWidth: true
            MokaidIcon { name: root.iconName; size: 18; color: root.accent }
            Item { Layout.fillWidth: true }
            MokaidLabel { text: root.value; font.pixelSize: 26; font.weight: Font.DemiBold; color: root.accent }
        }
        MokaidLabel { Layout.fillWidth: true; text: root.label; color: Theme.secondary; font.pixelSize: 11; elide: Text.ElideRight }
    }
}
