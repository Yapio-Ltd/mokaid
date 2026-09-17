import QtQuick
import QtQuick.Effects

Item {
    id: root
    property string kind: "male"
    property bool online: true
    property real size: 48
    implicitWidth: size; implicitHeight: size
    Rectangle {
        anchors.fill: parent; radius: width / 2
        gradient: Gradient { GradientStop { position: 0; color: "#383056" } GradientStop { position: 1; color: "#141725" } }
        border.color: "#7660ba"; border.width: 1
    }
    Image {
        id: portrait; anchors.fill: parent; anchors.margins: 3
        source: "qrc:/ui/portrait-" + (root.kind === "female" ? "design" : ["male", "design", "finance", "corporate", "developer", "research", "legal", "byte", "nyx", "moss"].indexOf(root.kind) >= 0 ? root.kind : "male") + ".png"
        fillMode: Image.PreserveAspectCrop; asynchronous: true; visible: false
    }
    Rectangle { id: mask; anchors.fill: portrait; radius: width/2; color: "white"; layer.enabled: true; visible: false }
    MultiEffect { anchors.fill: portrait; source: portrait; maskEnabled: true; maskSource: mask; maskThresholdMin: .5; maskSpreadAtMin: 1 }
    Rectangle {
        visible: root.online
        width: 8; height: 8; radius: 4
        anchors.left: parent.left; anchors.bottom: parent.bottom
        color: Theme.success; border.color: Theme.background; border.width: 2
    }
}
