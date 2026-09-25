pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs

ColumnLayout {
    id: root
    required property var controller
    property string selectedAssetId: ""
    property string agentName: ""
    property string sourceMode: "catalog"
    property url photo: ""
    property string prompt: ""
    property string acceptedGenerationId: ""
    property bool historyExpanded: false
    readonly property var job: controller.current || ({})
    readonly property string status: String(job.status || "")
    readonly property bool generating: ["queued", "generating", "texturing", "rigging", "saving"].indexOf(status) >= 0
    readonly property bool hasJob: !!job.id
    readonly property bool selectedReady: status === "ready" && acceptedGenerationId === job.id && selectedAssetId === job.asset_id
    readonly property bool readyForSubmit: sourceMode === "catalog" || (!!selectedAssetId && acceptedGenerationId === job.id && status === "ready")
    signal assetSelected(string assetId)
    spacing: 12
    function reset() {
        sourceMode = "catalog"; photo = ""; prompt = ""; acceptedGenerationId = ""; historyExpanded = false
        controller.refresh()
    }
    function stageLabel(stage) {
        const names = { queued: "Waiting to start", generating: "Shaping your character", texturing: "Adding colors and textures", rigging: "Preparing it to move", saving: "Saving your character", ready: "Your character is ready", failed: "This character could not be created", cancelled: "Generation cancelled" }
        return names[stage] || "Preparing your character"
    }
    function selectJob(id) {
        controller.selectGeneration(id)
        sourceMode = "image" === controller.current.mode ? "image" : "text"
        if (controller.current.prompt) prompt = String(controller.current.prompt)
    }
    function generate() {
        acceptedGenerationId = ""
        if (sourceMode === "image") controller.generateImage(photo, agentName)
        else controller.generateText(prompt, agentName)
    }
    RowLayout {
        Layout.fillWidth: true
        MokaidLabel { text: "Give your teammate a face"; font.pixelSize: 15; font.weight: Font.DemiBold; Layout.fillWidth: true; wrapMode: Text.Wrap }
        MokaidLabel { text: "3D character"; color: Theme.secondary; font.pixelSize: 11 }
    }
    RowLayout {
        Layout.fillWidth: true; spacing: 8
        Repeater {
            model: [{ key: "catalog", label: "Characters", icon: "agents" }, { key: "image", label: "From a photo", icon: "image" }, { key: "text", label: "Describe it", icon: "file" }]
            MokaidButton {
                required property var modelData
                objectName: "avatarSource_" + modelData.key
                Layout.fillWidth: true; Layout.minimumWidth: 0
                text: modelData.label; iconName: modelData.icon
                highlighted: root.sourceMode === modelData.key
                Accessible.name: "Character source: " + text
                Accessible.description: highlighted ? "Selected" : ""
                onClicked: root.sourceMode = modelData.key
            }
        }
    }
    ColumnLayout {
        visible: root.sourceMode === "catalog"
        Layout.fillWidth: true; spacing: 10
        MokaidLabel { Layout.fillWidth: true; text: "Pick a ready-made character, or create someone unique from a photo or a description."; color: Theme.secondary; font.pixelSize: 12; wrapMode: Text.Wrap }
        ScrollView {
            Layout.fillWidth: true; Layout.preferredHeight: 112
            contentHeight: availableHeight; clip: true
            ScrollBar.vertical.policy: ScrollBar.AlwaysOff
            Row {
                spacing: 8; height: 92
                Button {
                    id: defaultCharacter
                    objectName: "avatarDefault"
                    width: 90; height: 92; padding: 8
                    onClicked: { root.acceptedGenerationId = ""; root.assetSelected("") }
                    Accessible.name: "Default character"
                    background: Rectangle { radius: 10; color: root.selectedAssetId === "" ? Theme.selected : Theme.surface; border.color: defaultCharacter.visualFocus ? Theme.focusBorder : root.selectedAssetId === "" ? Theme.primary : Theme.border }
                    contentItem: ColumnLayout {
                        spacing: 4
                        WorkforcePortrait { Layout.alignment: Qt.AlignHCenter; agent: ({kind: "ai"}); size: 50 }
                        MokaidLabel { Layout.fillWidth: true; text: "Default"; font.pixelSize: 11; horizontalAlignment: Text.AlignHCenter }
                    }
                }
                Repeater {
                    model: root.controller.catalog
                    Button {
                        id: catalogCharacter
                        required property var modelData
                        objectName: "avatarCatalog_" + modelData.id
                        width: 94; height: 92; padding: 8
                        readonly property string characterName: String((modelData.metadata || {}).display_name || modelData.slug || "Character").replace(/^avatar_/, "").replace(/_/g, " ")
                        onClicked: { root.acceptedGenerationId = ""; root.assetSelected(String(modelData.id)) }
                        Accessible.name: characterName + (root.selectedAssetId === String(modelData.id) ? ", selected" : "")
                        background: Rectangle { radius: 10; color: root.selectedAssetId === String(catalogCharacter.modelData.id) ? Theme.selected : Theme.surface; border.color: catalogCharacter.visualFocus ? Theme.focusBorder : root.selectedAssetId === String(catalogCharacter.modelData.id) ? Theme.primary : Theme.border }
                        contentItem: ColumnLayout {
                            spacing: 4
                            WorkforcePortrait { Layout.alignment: Qt.AlignHCenter; size: 50; agent: ({kind: "ai", display_name: catalogCharacter.characterName, avatar_asset_id: catalogCharacter.modelData.id, avatar_cdn_path: catalogCharacter.modelData.cdn_path, avatar_thumbnail_url: (catalogCharacter.modelData.metadata || {}).thumbnail_url || ""}) }
                            MokaidLabel { Layout.fillWidth: true; text: catalogCharacter.characterName; font.pixelSize: 11; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight }
                        }
                    }
                }
            }
        }
    }
    ColumnLayout {
        visible: root.sourceMode !== "catalog" && !root.selectedReady
        Layout.fillWidth: true; spacing: 10
        MokaidLabel { Layout.fillWidth: true; text: root.sourceMode === "image" ? "Use a clear photo of one person, ideally showing the full body, with a simple background." : "Describe one full-body character: appearance, outfit and style. We’ll prepare it for your office."; color: Theme.secondary; font.pixelSize: 12; wrapMode: Text.Wrap }
        RowLayout {
            visible: root.sourceMode === "image"
            Layout.fillWidth: true; spacing: 14
            Rectangle {
                Layout.preferredWidth: 84; Layout.preferredHeight: 96; radius: 10; color: Theme.surface; border.color: Theme.border
                Image { anchors.fill: parent; anchors.margins: 4; source: root.photo; asynchronous: true; fillMode: Image.PreserveAspectFit; sourceSize.width: 168; sourceSize.height: 192 }
                MokaidIcon { anchors.centerIn: parent; visible: root.photo.toString().length === 0; name: "image"; size: 30; color: Theme.secondary }
            }
            ColumnLayout {
                Layout.fillWidth: true; spacing: 7
                MokaidButton { objectName: "avatarChoosePhoto"; text: root.photo.toString().length ? "Change photo" : "Choose a photo"; iconName: "folder"; onClicked: photoPicker.open() }
                MokaidLabel { Layout.fillWidth: true; text: root.photo.toString().length ? decodeURIComponent(root.photo.toString().split("/").pop()) : "PNG or JPEG · Up to 10 MB"; color: Theme.secondary; font.pixelSize: 11; elide: Text.ElideMiddle }
            }
        }
        ScrollView {
            visible: root.sourceMode === "text"
            Layout.fillWidth: true; Layout.preferredHeight: 90
            MokaidTextArea {
                objectName: "avatarPrompt"
                text: root.prompt; wrapMode: TextEdit.Wrap; selectByMouse: true
                placeholderText: "A friendly architect with curly hair, round glasses, a navy jacket and white sneakers. Stylized 3D, full body."
                Accessible.name: "Describe your 3D character"
                onTextChanged: root.prompt = text
            }
        }
        RowLayout {
            visible: root.sourceMode === "text"
            Layout.fillWidth: true
            MokaidButton { quiet: true; text: "Use example"; implicitHeight: 28; font.pixelSize: 11; onClicked: root.prompt = "A friendly architect with curly hair, round glasses, a navy jacket and white sneakers. Stylized 3D, full body." }
            Item { Layout.fillWidth: true }
            MokaidLabel { text: root.prompt.length + "/600"; color: root.prompt.length > 600 ? Theme.danger : Theme.muted; font.pixelSize: 11; Accessible.name: text + " characters" }
        }
        RowLayout {
            Layout.fillWidth: true; spacing: 12
            MokaidButton {
                objectName: "avatarGenerate"
                text: root.controller.submitting ? "Starting…" : "Create 3D character"; iconName: "agents"; highlighted: true
                enabled: root.controller.online && !root.controller.submitting && !root.generating && (root.sourceMode === "image" ? root.photo.toString().length > 0 : root.prompt.trim().length >= 3 && root.prompt.length <= 600)
                onClicked: root.generate()
            }
            MokaidLabel { Layout.fillWidth: true; text: "Takes a few minutes. Uses Meshy generation credits."; color: Theme.muted; font.pixelSize: 11; wrapMode: Text.Wrap }
        }
    }
    Rectangle {
        visible: root.hasJob && root.sourceMode !== "catalog"
        Layout.fillWidth: true; implicitHeight: resultContent.implicitHeight + 28
        radius: 12; color: Theme.surface; border.color: root.status === "ready" ? Theme.selectedBorder : Theme.border
        ColumnLayout {
            id: resultContent
            anchors.fill: parent; anchors.margins: 14; spacing: 10
            RowLayout {
                Layout.fillWidth: true; spacing: 12
                Image {
                    visible: source.toString().length > 0
                    Layout.preferredWidth: 90; Layout.preferredHeight: 112
                    source: root.job.thumbnail_url || ""; asynchronous: true; fillMode: Image.PreserveAspectFit
                    sourceSize.width: 180; sourceSize.height: 224
                    Accessible.name: "Generated character preview"
                }
                ColumnLayout {
                    Layout.fillWidth: true; spacing: 7
                    MokaidLabel { Layout.fillWidth: true; text: root.stageLabel(root.status); font.weight: Font.DemiBold; wrapMode: Text.Wrap }
                    MokaidLabel { Layout.fillWidth: true; text: root.status === "ready" ? "Sized to match your existing teammates at 1.75 m." : root.status === "failed" ? String(root.job.error || "Please try a clearer photo or a more specific description.") : "You can close this window and return to Your creations. Your character will keep generating."; color: root.status === "failed" ? Theme.warning : Theme.secondary; font.pixelSize: 11; wrapMode: Text.Wrap }
                    MokaidButton {
                        visible: root.status === "ready"
                        objectName: "avatarUseGenerated"
                        text: root.acceptedGenerationId === root.job.id && root.selectedAssetId === root.job.asset_id ? "Character selected" : "Use this character"
                        highlighted: true; enabled: !!root.job.asset_id
                        onClicked: { root.acceptedGenerationId = root.job.id; root.assetSelected(root.job.asset_id) }
                    }
                    MokaidButton { visible: root.selectedReady; text: "Create another"; quiet: true; implicitHeight: 30; onClicked: { root.acceptedGenerationId = ""; root.controller.clearCurrent() } }
                    MokaidButton { visible: root.status === "failed"; objectName: "avatarRetry"; text: "Try again"; enabled: root.controller.online && !root.controller.submitting && (root.sourceMode === "image" ? root.photo.toString().length > 0 : root.prompt.trim().length >= 3 && root.prompt.length <= 600); onClicked: root.generate() }
                }
            }
            RowLayout {
                visible: root.generating
                Layout.fillWidth: true
                ProgressBar { Layout.fillWidth: true; from: 0; to: 100; value: Math.max(0, Math.min(100, Number(root.job.progress || 0))); palette.highlight: Theme.primary; Accessible.name: "Character generation progress" }
                MokaidLabel { text: Math.round(Number(root.job.progress || 0)) + "%"; color: Theme.secondary; font.pixelSize: 11 }
            }
            MokaidButton { visible: root.generating; text: "Refresh progress"; quiet: true; implicitHeight: 30; onClicked: root.controller.refreshCurrent() }
        }
    }
    RowLayout {
        Layout.fillWidth: true
        MokaidButton { objectName: "avatarHistory"; text: "Your creations" + (root.controller.generations.length ? " (" + root.controller.generations.length + ")" : ""); iconName: root.historyExpanded ? "chevron-up" : "chevron-down"; quiet: true; implicitHeight: 30; onClicked: { root.historyExpanded = !root.historyExpanded; if (root.historyExpanded) root.controller.refresh() } }
        Item { Layout.fillWidth: true }
        MokaidButton { text: root.controller.refreshing ? "Refreshing…" : "Refresh"; quiet: true; implicitHeight: 30; enabled: !root.controller.refreshing && root.controller.online; onClicked: root.controller.refresh() }
    }
    ColumnLayout {
        visible: root.historyExpanded
        Layout.fillWidth: true; spacing: 6
        MokaidLabel { visible: root.controller.generations.length === 0; Layout.fillWidth: true; text: root.controller.refreshing ? "Loading your creations…" : "Characters you create will appear here, including those still in progress."; color: Theme.secondary; font.pixelSize: 11; wrapMode: Text.Wrap }
        Repeater {
            model: root.controller.generations
            MokaidButton {
                required property var modelData
                objectName: "avatarHistory_" + modelData.id
                Layout.fillWidth: true
                text: String(modelData.name || (modelData.mode === "image" ? "Character from photo" : "Character from description")) + " · " + root.stageLabel(String(modelData.status))
                highlighted: root.job.id === modelData.id
                onClicked: root.selectJob(modelData.id)
            }
        }
    }
    MokaidLabel { visible: root.controller.error.length > 0; Layout.fillWidth: true; text: root.controller.error; color: Theme.warning; font.pixelSize: 12; wrapMode: Text.Wrap }
    MokaidLabel { visible: !root.readyForSubmit && root.sourceMode !== "catalog"; Layout.fillWidth: true; text: "Select your finished character to add the agent, or choose a ready-made character."; color: Theme.secondary; font.pixelSize: 11; wrapMode: Text.Wrap }
    Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.divider }
    FileDialog {
        id: photoPicker
        title: "Choose a photo for your 3D character"
        fileMode: FileDialog.OpenFile
        nameFilters: ["Images (*.png *.jpg *.jpeg)"]
        onAccepted: root.photo = selectedFile
    }
}
