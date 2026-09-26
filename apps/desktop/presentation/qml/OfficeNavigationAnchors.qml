pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls

Item {
    id: root
    property var sceneViewport: null
    property var agents: []
    property bool reducedMotion: false
    signal destinationRequested(string stopId)

    function destinationName(seat, fallback) {
        if (seat < 0) return fallback
        for (let i = 0; i < agents.length; ++i) {
            const agent = agents[i]
            if (agent.seat_index === seat)
                return agent.display_name || agent.name || fallback
        }
        return fallback
    }

    Repeater {
        model: root.sceneViewport ? root.sceneViewport.tourAnchors : null
        delegate: AbstractButton {
            id: marker
            required property string stopId
            required property string stopLabel
            required property int seatIndex
            required property real screenX
            required property real screenY
            required property real distance
            required property real markerScale
            required property bool onScreen
            required property bool destination
            readonly property string destinationName: root.destinationName(seatIndex, stopLabel)
            readonly property bool emphasized: hovered || activeFocus || destination
            objectName: "officeAnchor_" + stopId
            x: screenX - width / 2
            y: screenY - height / 2
            width: 44; height: 44
            visible: onScreen
            hoverEnabled: true
            focusPolicy: Qt.StrongFocus
            z: emphasized ? 2 : 1
            Accessible.role: Accessible.Button
            Accessible.name: qsTr("Walk to %1").arg(destinationName)
            Accessible.description: qsTr("Follow the clear aisle to this place in the office.")
            onClicked: root.destinationRequested(stopId)

            background: Item {
                Rectangle {
                    anchors.centerIn: parent
                    width: 44 * marker.markerScale; height: width * .58
                    radius: width / 2
                    color: "#188e6cff"
                    border.color: marker.emphasized ? "#777c59ee" : "#228c70cc"
                    antialiasing: true
                    opacity: marker.emphasized ? 1 : .7
                }
                Rectangle {
                    id: halo
                    anchors.centerIn: parent
                    width: 32 * marker.markerScale; height: width * .58
                    radius: width / 2
                    color: marker.emphasized ? "#558a67e7" : "#382f2447"
                    border.width: marker.emphasized ? 2 : 1.4
                    border.color: marker.emphasized ? "#f0dcff" : "#c5a8f9"
                    antialiasing: true
                    SequentialAnimation on opacity {
                        running: marker.destination && marker.visible && !root.reducedMotion
                        loops: Animation.Infinite
                        NumberAnimation { from: 1; to: .50; duration: 700; easing.type: Easing.InOutSine }
                        NumberAnimation { from: .50; to: 1; duration: 700; easing.type: Easing.InOutSine }
                    }
                }
                Rectangle {
                    anchors.centerIn: parent
                    width: 8 * marker.markerScale; height: width * .58
                    radius: width / 2; color: "#ecdfff"; antialiasing: true
                }
            }
            contentItem: Item {
                Rectangle {
                    visible: marker.emphasized
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.top
                    anchors.bottomMargin: -3
                    width: Math.min(190, caption.implicitWidth + 20)
                    height: 29
                    radius: 7
                    color: "#f0161325"
                    border.color: marker.activeFocus ? Theme.focusBorder : "#807b5cad"
                    MokaidLabel {
                        id: caption
                        anchors.centerIn: parent
                        width: Math.min(170, implicitWidth)
                        text: marker.destination ? qsTr("Walking to %1").arg(marker.destinationName) : marker.destinationName
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        font.pixelSize: 11; font.weight: Font.DemiBold
                        color: "#ede5ff"
                    }
                }
            }
        }
    }
}
