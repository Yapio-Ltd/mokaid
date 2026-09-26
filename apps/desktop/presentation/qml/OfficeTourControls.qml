import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: root
    required property var sceneViewport
    property var agents: []
    property bool mapExpanded: true
    readonly property var destinations: sceneViewport.tourStops.map(function(stop) {
        var agent = root.agents.find(function(a) { return a.seat_index === stop.seat && stop.seat >= 0 })
        return { id: stop.id, displayLabel: agent ? (agent.display_name || agent.name) + " · Desk " + (stop.seat + 1) : stop.label,
                 x: stop.x, z: stop.z, seat: stop.seat }
    })
    function labelFor(id) {
        var stop = destinations.find(function(s) { return s.id === id })
        return stop ? stop.displayLabel : "Choose a destination"
    }
    width: 270; height: controls.implicitHeight + 24
    radius: Theme.radiusPanel; color: "#f5111320"; border.color: Theme.border
    MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onWheel: function(wheel) { wheel.accepted = true } }
    ColumnLayout {
        id: controls
        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
        anchors.margins: 12; spacing: 10
        RowLayout {
            Layout.fillWidth: true; spacing: 8
            MokaidLabel { Layout.fillWidth: true; text: "Explore the office"; font.weight: Font.DemiBold; font.pixelSize: 13 }
            MokaidButton {
                objectName: "officeTourMapToggle"
                implicitWidth: 32; implicitHeight: 32; quiet: true
                iconName: root.mapExpanded ? "chevron-down" : "chevron-up"
                Accessible.name: root.mapExpanded ? "Hide route map" : "Show route map"
                onClicked: root.mapExpanded = !root.mapExpanded
            }
        }
        MokaidComboBox {
            id: destination
            objectName: "officeTourDestination"
            Layout.fillWidth: true
            model: root.destinations; textRole: "displayLabel"; valueRole: "id"
            displayText: root.labelFor(root.sceneViewport.tourDestination || root.sceneViewport.tourCurrentStop)
            Accessible.name: "Walk to a desk or shared space"
            onActivated: root.sceneViewport.travelTo(currentValue)
        }
        Item {
            id: map
            objectName: "officeTourMap"
            visible: root.mapExpanded
            Layout.fillWidth: true; Layout.preferredHeight: visible ? 178 : 0
            readonly property real minX: Math.min(-7, ...root.destinations.map(function(s) { return s.x })) - .5
            readonly property real maxX: Math.max(7, ...root.destinations.map(function(s) { return s.x })) + .5
            readonly property real minZ: Math.min(-6, ...root.destinations.map(function(s) { return s.z })) - .5
            readonly property real maxZ: Math.max(6, ...root.destinations.map(function(s) { return s.z })) + .5
            function px(x) { return 14 + (x - minX) / (maxX - minX) * (width - 28) }
            function py(z) { return 14 + (maxZ - z) / (maxZ - minZ) * (height - 28) }
            Rectangle { anchors.fill: parent; color: "#0c0d17"; radius: 10 }
            Canvas {
                id: lanes
                anchors.fill: parent
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()
                onVisibleChanged: requestPaint()
                Connections { target: root.sceneViewport; function onTourEdgesChanged() { lanes.requestPaint() } }
                onPaint: {
                    var ctx = getContext("2d")
                    ctx.reset(); ctx.lineWidth = 2; ctx.strokeStyle = "#756198"; ctx.lineJoin = "round"; ctx.lineCap = "round"
                    root.sceneViewport.tourEdges.forEach(function(edge) {
                        ctx.beginPath()
                        edge.points.forEach(function(p, index) { if (index === 0) ctx.moveTo(map.px(p.x), map.py(p.z)); else ctx.lineTo(map.px(p.x), map.py(p.z)) })
                        ctx.stroke()
                    })
                }
            }
            Repeater {
                model: root.destinations
                delegate: AbstractButton {
                    id: stopButton
                    required property var modelData
                    objectName: "officeTourStop_" + modelData.id
                    width: 24; height: 24
                    x: map.px(modelData.x) - 12; y: map.py(modelData.z) - 12
                    hoverEnabled: true; focusPolicy: Qt.StrongFocus
                    Accessible.name: "Walk to " + modelData.displayLabel
                    onClicked: root.sceneViewport.travelTo(modelData.id)
                    background: Rectangle {
                        anchors.centerIn: parent; width: 15; height: 15; radius: 7.5
                        color: root.sceneViewport.tourDestination === stopButton.modelData.id ? Theme.primary : "#272035"
                        border.color: stopButton.visualFocus || stopButton.hovered ? Theme.text : "#bc9bf1"
                        border.width: stopButton.visualFocus ? 2 : 1
                    }
                    contentItem: MokaidLabel {
                        text: stopButton.modelData.seat >= 0 ? stopButton.modelData.seat + 1 : ""
                        font.pixelSize: 9; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                    }
                    ToolTip.visible: hovered || activeFocus
                    ToolTip.text: modelData.displayLabel
                    ToolTip.delay: 250
                }
            }
            Item {
                x: map.px(root.sceneViewport.tourPosition.x) - 5
                y: map.py(root.sceneViewport.tourPosition.y) - 5
                width: 10; height: 10
                rotation: root.sceneViewport.tourYaw * 180 / Math.PI
                Rectangle { x: 4; y: -6; width: 2; height: 9; color: "#8ce6d0" }
                Rectangle { anchors.fill: parent; radius: 5; color: "#8ce6d0"; border.color: "#0c0d17"; border.width: 2 }
                Accessible.role: Accessible.Indicator; Accessible.name: "Your position"
            }
        }
        RowLayout {
            Layout.fillWidth: true; spacing: 6
            MokaidLabel {
                Layout.fillWidth: true; font.pixelSize: 11; color: Theme.secondary; wrapMode: Text.Wrap
                text: root.sceneViewport.tourMoving ? "Walking to " + root.labelFor(root.sceneViewport.tourDestination) : "Choose a stop. Follow the marked paths."
            }
            MokaidButton {
                visible: root.sceneViewport.tourMoving; iconName: "stop"; quiet: true
                implicitWidth: 32; implicitHeight: 32
                Accessible.name: "Pause walk"; onClicked: root.sceneViewport.stopWalking()
            }
        }
    }
}
