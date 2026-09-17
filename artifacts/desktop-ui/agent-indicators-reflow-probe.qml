import QtQuick
Rectangle {
    width: 700; height: 600; color: "#0d101c"
    AgentIndicators { anchors.fill: parent; model: indicatorModel; reducedMotion: false }
}
