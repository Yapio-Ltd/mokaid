pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects

Item {
    id: root
    property var agent: ({})
    property real size: 58
    readonly property bool softwareRendering: GraphicsInfo.api === GraphicsInfo.Software
    implicitWidth: size
    implicitHeight: size

    // The office uses the bundled catalog character across GLB revisions.
    // Resolve the same character here: persisted API records can still refer to
    // an older hash than the sources used to render assets/provenance.json.
    // Custom locations and unresolved assignments must not borrow another face.
    readonly property string portraitSource: {
        if (agent.kind !== "ai" && agent.kind !== "hybrid") return ""
        const path = String(agent.avatar_cdn_path || "").trim()
        if (!path) return agent.avatar_asset_id ? "" : "qrc:/ui/portrait-male.png"
        const match = /^(?:(?:https?:\/\/[^/?#]+)?\/?assets3d\/|assets\/optimized\/)avatar_(male|design|finance|corporate|developer|research|legal|byte|nyx|moss)(?:\.[a-f0-9]+)?\.glb(?:[?#].*)?$/.exec(path)
        return match ? "qrc:/ui/portrait-" + match[1] + ".png" : ""
    }
    readonly property string initials: {
        const words = String(agent.display_name || agent.name || "?").trim().split(/\s+/)
        return (words[0].charAt(0) + (words.length > 1 ? words[words.length - 1].charAt(0) : "")).toUpperCase()
    }
    Rectangle {
        anchors.fill: parent
        radius: width / 2
        gradient: Gradient {
            GradientStop { position: 0; color: "#292844" }
            GradientStop { position: 1; color: "#151729" }
        }
        border.width: 1
        border.color: "#68569f"
    }
    MokaidLabel {
        anchors.centerIn: parent
        visible: portrait.status !== Image.Ready
        text: root.initials
        font.pixelSize: root.size * .29
        font.weight: Font.DemiBold
        color: "#d8c9ff"
    }
    Image {
        id: portrait
        anchors.fill: parent
        anchors.margins: 2
        source: root.portraitSource
        sourceSize.width: 192
        sourceSize.height: 192
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        visible: root.softwareRendering
    }
    Rectangle {
        id: mask
        anchors.fill: portrait
        radius: width / 2
        color: "white"
        layer.enabled: true
        visible: false
    }
    MultiEffect {
        anchors.fill: portrait
        source: portrait
        visible: !root.softwareRendering && portrait.status === Image.Ready
        maskEnabled: true
        maskSource: mask
        maskThresholdMin: .5
        maskSpreadAtMin: 1
    }
    Accessible.role: Accessible.Graphic
    Accessible.name: String(root.agent.display_name || "Agent") + " avatar"
}
