pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Shapes

// Moked's floating seed: one continuous nacre shell, ink eyes and a violet leaf.
// All motion stays on scene-graph properties; no per-frame JavaScript painting.
Item {
    id: root
    implicitWidth: 150
    implicitHeight: 156

    property string mode: "idle"
    property bool reducedMotion: false
    property bool animated: true
    property real audioLevel: 0
    readonly property bool motionEnabled: animated && visible && !reducedMotion
    readonly property bool working: mode === "working"
    readonly property bool listening: mode === "listening"
    readonly property bool speaking: mode === "speaking"
    readonly property bool voiceActive: listening || speaking

    property real floatOffset: 0
    property real blink: 1
    property real lookOffset: 0
    property real typingOffset: 0
    property real voicePhase: 0

    SequentialAnimation {
        running: root.motionEnabled
        loops: Animation.Infinite
        onRunningChanged: if (!running) root.floatOffset = 0
        NumberAnimation { target: root; property: "floatOffset"; from: 0; to: -4; duration: 1850; easing.type: Easing.InOutSine }
        NumberAnimation { target: root; property: "floatOffset"; to: 0; duration: 1850; easing.type: Easing.InOutSine }
    }
    SequentialAnimation {
        running: root.motionEnabled
        loops: Animation.Infinite
        onRunningChanged: if (!running) root.blink = 1
        PauseAnimation { duration: 3900 }
        NumberAnimation { target: root; property: "blink"; to: 0.10; duration: 75 }
        PauseAnimation { duration: 75 }
        NumberAnimation { target: root; property: "blink"; to: 1; duration: 140; easing.type: Easing.OutCubic }
        PauseAnimation { duration: 1700 }
    }
    SequentialAnimation {
        running: root.motionEnabled && root.mode === "thinking"
        loops: Animation.Infinite
        onRunningChanged: if (!running) root.lookOffset = 0
        NumberAnimation { target: root; property: "lookOffset"; to: 3; duration: 420; easing.type: Easing.OutCubic }
        PauseAnimation { duration: 1200 }
        NumberAnimation { target: root; property: "lookOffset"; to: -2; duration: 500; easing.type: Easing.InOutCubic }
        PauseAnimation { duration: 900 }
    }
    SequentialAnimation {
        running: root.motionEnabled && root.working
        loops: Animation.Infinite
        onRunningChanged: if (!running) root.typingOffset = 0
        NumberAnimation { target: root; property: "typingOffset"; from: -1.5; to: 1.5; duration: 160; easing.type: Easing.InOutSine }
        NumberAnimation { target: root; property: "typingOffset"; to: -1.5; duration: 180; easing.type: Easing.InOutSine }
    }
    NumberAnimation {
        target: root; property: "voicePhase"; from: 0; to: Math.PI * 2
        duration: root.speaking ? 650 : 1250
        loops: Animation.Infinite
        running: root.motionEnabled && root.voiceActive
    }

    Item {
        id: scene
        width: 150; height: 156
        anchors.centerIn: parent
        scale: Math.min(root.width / width, root.height / height)

        // Three quiet ellipses give the floating body a soft contact shadow.
        Rectangle {
            x: 40; y: 136; width: 76; height: 10; radius: 38
            color: "#08070f"; opacity: 0.12
            scale: 1 + root.floatOffset / 32
        }
        Rectangle {
            x: 48; y: 138; width: 60; height: 6; radius: 30
            color: "#08070f"; opacity: 0.18
            scale: 1 + root.floatOffset / 32
        }

        Item {
            id: companion
            width: 150; height: 144
            y: root.floatOffset
            rotation: root.listening ? -4 : root.mode === "thinking" ? 3 : 0
            Behavior on rotation { NumberAnimation { duration: root.reducedMotion ? 0 : 380; easing.type: Easing.OutCubic } }

            // The two floating mittens move forward to the keyboard while working.
            Rectangle {
                x: root.working ? 42 : 25
                y: (root.working ? 100 : 87) + (root.working ? root.typingOffset : 0)
                width: 16; height: 25; radius: 8
                rotation: root.working ? -54 : 23
                gradient: Gradient {
                    GradientStop { position: 0; color: "#d2baff" }
                    GradientStop { position: 1; color: "#8d5edf" }
                }
                Behavior on x { NumberAnimation { duration: root.reducedMotion ? 0 : 280; easing.type: Easing.OutCubic } }
                Behavior on rotation { NumberAnimation { duration: root.reducedMotion ? 0 : 280; easing.type: Easing.OutCubic } }
            }
            Rectangle {
                x: root.working ? 100 : 112
                y: (root.working ? 99 : 86) - (root.working ? root.typingOffset : 0)
                width: 16; height: 25; radius: 8
                rotation: root.working ? 54 : -25
                gradient: Gradient {
                    GradientStop { position: 0; color: "#c4a6fa" }
                    GradientStop { position: 1; color: "#8151d6" }
                }
                Behavior on x { NumberAnimation { duration: root.reducedMotion ? 0 : 280; easing.type: Easing.OutCubic } }
                Behavior on rotation { NumberAnimation { duration: root.reducedMotion ? 0 : 280; easing.type: Easing.OutCubic } }
            }

            // Asymmetric seed outline, rather than a robot helmet or a pixel sprite.
            Shape {
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer
                ShapePath {
                    strokeWidth: 1
                    strokeColor: "#b398eb"
                    fillGradient: LinearGradient {
                        x1: 49; y1: 30; x2: 101; y2: 124
                        GradientStop { position: 0; color: "#f5edff" }
                        GradientStop { position: 0.38; color: "#ddcaff" }
                        GradientStop { position: 0.74; color: "#b28bea" }
                        GradientStop { position: 1; color: "#8353d2" }
                    }
                    startX: 78; startY: 27
                    PathCubic { x: 118; y: 63; control1X: 103; control1Y: 28; control2X: 119; control2Y: 41 }
                    PathCubic { x: 93; y: 125; control1X: 117; control1Y: 98; control2X: 113; control2Y: 119 }
                    PathCubic { x: 42; y: 107; control1X: 69; control1Y: 134; control2X: 48; control2Y: 125 }
                    PathCubic { x: 42; y: 48; control1X: 34; control1Y: 84; control2X: 31; control2Y: 62 }
                    PathCubic { x: 78; y: 27; control1X: 50; control1Y: 34; control2X: 65; control2Y: 26 }
                }
                // A small nacre glint follows the contour, like a ceramic object.
                ShapePath {
                    strokeWidth: 2.3
                    strokeColor: "#b3ffffff"
                    fillColor: "transparent"
                    capStyle: ShapePath.RoundCap
                    startX: 48; startY: 47
                    PathCubic { x: 73; y: 34; control1X: 54; control1Y: 39; control2X: 64; control2Y: 34 }
                }
            }

            // A folded leaf is the companion's distinct silhouette and state light.
            Shape {
                x: 76; y: 7; width: 34; height: 28
                rotation: root.listening ? 8 : -6
                preferredRendererType: Shape.CurveRenderer
                Behavior on rotation { NumberAnimation { duration: root.reducedMotion ? 0 : 350; easing.type: Easing.OutBack } }
                ShapePath {
                    strokeColor: "#c5a0ff"; strokeWidth: 0.7
                    fillGradient: LinearGradient {
                        x1: 0; y1: 28; x2: 30; y2: 1
                        GradientStop { position: 0; color: "#8151dc" }
                        GradientStop { position: 1; color: root.listening ? "#89ebd0" : "#c7a6ff" }
                    }
                    startX: 4; startY: 27
                    PathCubic { x: 30; y: 1; control1X: 2; control1Y: 8; control2X: 16; control2Y: 0 }
                    PathCubic { x: 4; y: 27; control1X: 32; control1Y: 18; control2X: 24; control2Y: 29 }
                }
                ShapePath {
                    fillColor: "transparent"; strokeColor: "#70f4eaff"; strokeWidth: 1
                    startX: 5; startY: 27
                    PathCubic { x: 25; y: 7; control1X: 12; control1Y: 18; control2X: 19; control2Y: 15 }
                }
            }

            Item {
                id: expression
                x: 47 + root.lookOffset; y: root.working ? 61 : 60
                width: 55; height: 36
                Behavior on y { NumberAnimation { duration: root.reducedMotion ? 0 : 250 } }

                Repeater {
                    model: 2
                    Item {
                        required property int index
                        x: index === 0 ? 8 : 36
                        y: root.working ? 5 : 0
                        width: 10; height: root.listening ? 17 : 15
                        transform: Scale { origin.x: 5; origin.y: 7; yScale: root.blink }
                        Rectangle {
                            anchors.fill: parent
                            radius: 5
                            color: "#302147"
                        }
                        Rectangle {
                            x: 2; y: 2; width: 3; height: 4; radius: 1.5
                            color: "#eee0ff"; opacity: 0.75
                        }
                    }
                }
                Shape {
                    y: 20; width: 55; height: 13
                    opacity: root.voiceActive ? 0 : 0.85
                    preferredRendererType: Shape.CurveRenderer
                    ShapePath {
                        fillColor: "transparent"
                        strokeColor: "#644379"; strokeWidth: 1.8
                        capStyle: ShapePath.RoundCap
                        startX: 23; startY: 2
                        PathCubic { x: 33; y: 2; control1X: 26; control1Y: 6; control2X: 30; control2Y: 6 }
                    }
                    Behavior on opacity { NumberAnimation { duration: root.reducedMotion ? 0 : 150 } }
                }
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: 24; spacing: 2.5
                    height: 14
                    opacity: root.voiceActive ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: root.reducedMotion ? 0 : 150 } }
                    Repeater {
                        model: 5
                        Rectangle {
                            required property int index
                            readonly property real envelope: Math.max(0, 1 - Math.abs(index - 2) * 0.27)
                            readonly property real energy: root.reducedMotion ? 0.65 :
                                Math.max(Math.min(root.audioLevel, 1), 0.20 + 0.55 * Math.abs(Math.sin(root.voicePhase + index * 0.8)))
                            anchors.verticalCenter: parent.verticalCenter
                            width: 3; height: 3 + 11 * envelope * energy
                            radius: 1.5
                            color: root.listening ? "#356d67" : "#6a429b"
                        }
                    }
                }
            }

            // The computer rises from below, with hands visible at the keyboard.
            Item {
                id: laptop
                x: 44; y: root.working ? 92 : 114
                width: 82; height: 44
                opacity: root.working ? 1 : 0
                scale: root.working ? 1 : 0.72
                rotation: -5
                visible: opacity > 0
                Behavior on y { NumberAnimation { duration: root.reducedMotion ? 0 : 420; easing.type: Easing.OutCubic } }
                Behavior on opacity { NumberAnimation { duration: root.reducedMotion ? 0 : 200 } }
                Behavior on scale { NumberAnimation { duration: root.reducedMotion ? 0 : 420; easing.type: Easing.OutCubic } }
                Rectangle {
                    x: 4; y: 0; width: 73; height: 41; radius: 7
                    border.color: "#a780e6"; border.width: 1
                    gradient: Gradient {
                        GradientStop { position: 0; color: "#51406d" }
                        GradientStop { position: 1; color: "#292037" }
                    }
                    // Moked's two seed marks are engraved on the laptop lid.
                    Rectangle { x: 29; y: 14; width: 6; height: 14; radius: 3; rotation: -22; color: "#d4b4ff" }
                    Rectangle { x: 38; y: 14; width: 6; height: 14; radius: 3; rotation: 22; color: "#ac85ff" }
                }
                Rectangle { x: 0; y: 38; width: 82; height: 5; radius: 2.5; color: "#9c7fc3" }
                Rectangle { x: 30; y: 38; width: 23; height: 2; radius: 1; color: "#d7c6ee" }
            }
        }
    }
}
