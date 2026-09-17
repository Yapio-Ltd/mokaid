import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs

// A retained workspace sheet: hiding it never discards the mission draft.
Rectangle {
    id: root
    visible: missions.opened
    color: Theme.deep
    radius: Theme.radiusPanel
    border.color: Theme.border
    property var previousFocus: null
    property string previousStep: "describe"
    readonly property bool reviewing: missions.step === "recommend" || missions.step === "launching"
    readonly property bool delivered: missions.step === "done"
    readonly property var recommendation: missions.analysis.recommendation || ({})
    readonly property var proposedTask: missions.analysis.task || ({})
    onHeightChanged: if (visible && reviewing && missions.customSelected) Qt.callLater(root.focusCustomAgent)
    onVisibleChanged: {
        if (visible) {
            previousFocus = Window.window ? Window.window.activeFocusItem : null
            Qt.callLater(root.focusCurrentStep)
        } else if (previousFocus) previousFocus.forceActiveFocus()
    }
    function sizeLabel(bytes) { return bytes >= 1000000 ? (bytes / 1000000).toFixed(1) + " MB" : Math.max(1, Math.ceil(bytes / 1000)) + " KB" }
    function focusCustomAgent() {
        const top = customFields.mapToItem(scrollBody, 0, 0).y
        scroll.contentItem.contentY = Math.min(Math.max(0, top - 12), Math.max(0, scroll.contentItem.contentHeight - scroll.availableHeight))
        agentName.forceActiveFocus()
    }
    function focusCurrentStep() {
        if (root.reviewing && missions.customSelected) focusCustomAgent()
        else if (root.reviewing) continueButton.forceActiveFocus()
        else if (root.delivered) followMission.forceActiveFocus()
        else if (missions.step === "describe") instruction.forceActiveFocus()
    }
    function reviewOrLaunch() { if (!missions.busy && session.online) { if (root.reviewing && missions.canLaunch) missions.launch(); else if (!root.delivered) missions.analyze() } }
    Connections {
        target: missions
        function onChanged() {
            if (root.previousStep !== missions.step) {
                root.previousStep = missions.step; scroll.contentItem.contentY = 0
                if (root.visible) Qt.callLater(root.focusCurrentStep)
            }
        }
    }
    Keys.onEscapePressed: missions.close()
    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Return && (event.modifiers & (Qt.ControlModifier | Qt.MetaModifier))) { root.reviewOrLaunch(); event.accepted = true }
    }
    // Prevent clicks on this sheet from reaching the office underneath.
    MouseArea { anchors.fill: parent; onPressed: function(mouse) { mouse.accepted = true } }
    ColumnLayout {
        anchors.fill: parent; anchors.margins: 26; spacing: 18
        RowLayout {
            Layout.fillWidth: true; spacing: 14
            MokaidIcon { name: root.delivered ? "tasks" : "bolt"; size: 25; color: root.delivered ? Theme.success : Theme.primary }
            ColumnLayout {
                Layout.fillWidth: true; spacing: 4
                MokaidLabel { Layout.fillWidth: true; text: root.delivered ? "Your mission is underway" : root.reviewing ? "The right agent for the job" : "What shall we work on?"; font.pixelSize: 25; font.weight: Font.DemiBold; wrapMode: Text.Wrap }
                MokaidLabel { Layout.fillWidth: true; text: root.delivered ? "Follow the work from your office." : root.reviewing ? "Review the match, then hand it over." : "Bring your files. Describe the outcome. We’ll find the fit."; color: Theme.secondary; wrapMode: Text.Wrap; font.pixelSize: 12 }
            }
            MokaidIconButton { iconName: "close"; hint: "Close mission sheet; keep draft"; onClicked: missions.close() }
        }
        RowLayout {
            visible: !root.delivered; Layout.fillWidth: true; spacing: 12
            MokaidLabel { text: "1  Brief"; color: root.reviewing ? Theme.secondary : Theme.text; font.weight: root.reviewing ? Font.Normal : Font.DemiBold }
            Rectangle { Layout.fillWidth: true; height: 1; color: Theme.divider }
            MokaidLabel { text: "2  Match"; color: root.reviewing ? Theme.text : Theme.muted; font.weight: root.reviewing ? Font.DemiBold : Font.Normal }
            Rectangle { Layout.fillWidth: true; height: 1; color: Theme.divider }
            MokaidLabel { text: "3  Work"; color: Theme.muted }
        }
        ScrollView {
            id: scroll
            Layout.fillWidth: true; Layout.fillHeight: true; clip: true
            contentWidth: availableWidth
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ColumnLayout {
                id: scrollBody
                width: scroll.availableWidth; spacing: 18
                ColumnLayout {
                    visible: !root.reviewing && !root.delivered; Layout.fillWidth: true; spacing: 12
                    MokaidTextArea {
                        id: instruction; objectName: "missionInstruction"
                        Layout.fillWidth: true; Layout.preferredHeight: 152
                        text: missions.instruction; readOnly: missions.busy
                        placeholderText: "For example: compare these proposals and give me a clear recommendation."
                        wrapMode: TextEdit.Wrap; Accessible.name: "Mission brief"
                        onTextChanged: if (missions.instruction !== text) missions.instruction = text
                    }
                    MokaidLabel { text: "Include the result you expect, your constraints, and anything the agent should check."; Layout.fillWidth: true; color: Theme.muted; font.pixelSize: 12; wrapMode: Text.Wrap }
                    Flow {
                        Layout.fillWidth: true; spacing: 8; visible: missions.instruction.length === 0 && missions.attachments.length === 0
                        Repeater {
                            model: ["Analyze documents", "Build a website", "Prepare a report"]
                            MokaidButton {
                                required property string modelData
                                text: modelData; implicitHeight: 34; quiet: true
                                onClicked: { missions.instruction = modelData + ": "; instruction.forceActiveFocus() }
                            }
                        }
                    }
                    AbstractButton {
                        id: addFiles; objectName: "missionAddFiles"; Layout.fillWidth: true; Layout.preferredHeight: 84
                        enabled: !missions.busy; hoverEnabled: true
                        Accessible.name: "Add mission files. All file formats accepted."
                        onClicked: filePicker.open()
                        background: Rectangle { radius: 12; color: addFiles.hovered || drop.containsDrag ? Theme.selected : Theme.surface; border.color: addFiles.activeFocus || drop.containsDrag ? Theme.focusBorder : Theme.border }
                        contentItem: RowLayout {
                            anchors.fill: parent; anchors.margins: 18; spacing: 14
                            MokaidIcon { name: "file"; size: 25; color: Theme.primary }
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 5
                                MokaidLabel { text: "Drop files here or browse"; font.weight: Font.DemiBold }
                                MokaidLabel { Layout.fillWidth: true; text: "Documents, images, data, code, archives · up to 49 MB per file"; color: Theme.secondary; font.pixelSize: 11; wrapMode: Text.Wrap }
                            }
                            MokaidIcon { name: "plus"; size: 18 }
                        }
                    }
                }
                ColumnLayout {
                    visible: missions.attachments.length > 0 && !root.delivered; Layout.fillWidth: true; spacing: 2
                    MokaidLabel { text: "Files · " + missions.attachments.length; font.weight: Font.DemiBold; Layout.bottomMargin: 8 }
                    Repeater {
                        model: missions.attachments
                        RowLayout {
                            required property var modelData
                            Layout.fillWidth: true; spacing: 10
                            MokaidIcon { name: modelData.status === "ready" ? "tasks" : "file"; color: modelData.status === "ready" ? Theme.success : Theme.secondary; size: 17 }
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 3
                                MokaidLabel { Layout.fillWidth: true; text: modelData.name; elide: Text.ElideMiddle; font.pixelSize: 12 }
                                MokaidLabel { Layout.fillWidth: true; text: modelData.error || (root.sizeLabel(modelData.size_bytes || 0) + " · " + (modelData.status === "ready" ? "Attached" : modelData.status === "uploading" ? "Uploading…" : "Waiting to upload")); color: modelData.error ? Theme.warning : Theme.muted; font.pixelSize: 11; wrapMode: Text.Wrap }
                            }
                            BusyIndicator { running: modelData.status === "uploading"; visible: running; Layout.preferredWidth: 24; Layout.preferredHeight: 24 }
                            MokaidButton { visible: !!modelData.error && !missions.busy; text: "Retry"; onClicked: missions.retryFile(modelData.id) }
                            MokaidIconButton { visible: !root.reviewing; iconName: "close"; hint: "Remove " + modelData.name; enabled: !missions.busy; onClicked: missions.removeFile(modelData.id) }
                        }
                    }
                }
                ColumnLayout {
                    visible: root.reviewing; Layout.fillWidth: true; spacing: 14
                    MokaidLabel { text: root.proposedTask.title || "Your mission"; Layout.fillWidth: true; font.pixelSize: 19; font.weight: Font.DemiBold; wrapMode: Text.Wrap }
                    MokaidLabel { text: root.proposedTask.description || missions.instruction; Layout.fillWidth: true; color: Theme.secondary; wrapMode: Text.Wrap; maximumLineCount: 5; elide: Text.ElideRight }
                    MokaidLabel { text: root.recommendation.reason || "Choose the agent you want to work with."; Layout.fillWidth: true; color: Theme.text; wrapMode: Text.Wrap }
                    Repeater {
                        model: missions.candidates
                        AbstractButton {
                            id: candidate
                            required property var modelData
                            Layout.fillWidth: true; implicitHeight: candidateBody.implicitHeight + 28
                            enabled: !missions.busy && !missions.launchUncertain; hoverEnabled: true
                            readonly property bool selected: !missions.customSelected && missions.selectedAgentId === modelData.id
                            Accessible.name: modelData.display_name + ", " + (modelData.role_title || "Agent") + (selected ? ", selected" : "")
                            onClicked: missions.selectAgent(modelData.id)
                            background: Rectangle { radius: 12; color: candidate.selected ? Theme.selected : candidate.hovered ? Theme.hover : Theme.surface; border.color: candidate.activeFocus ? Theme.focusBorder : candidate.selected ? Theme.selectedBorder : Theme.border }
                            contentItem: RowLayout {
                                id: candidateBody; anchors.fill: parent; anchors.margins: 14; spacing: 12
                                MokaidIcon { name: candidate.selected ? "tasks" : "agents"; color: candidate.selected ? Theme.primary : Theme.secondary; size: 22 }
                                ColumnLayout {
                                    Layout.fillWidth: true; spacing: 5
                                    MokaidLabel { text: candidate.modelData.display_name; font.weight: Font.DemiBold; Layout.fillWidth: true; elide: Text.ElideRight }
                                    MokaidLabel { text: candidate.modelData.role_title || "Agent"; color: Theme.secondary; Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: 12 }
                                    MokaidLabel { visible: !!candidate.modelData.reason; text: candidate.modelData.reason || ""; color: Theme.muted; Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: 11 }
                                }
                                MokaidLabel { visible: candidate.modelData.recommended === true; text: "Suggested"; color: Theme.primary; font.pixelSize: 11 }
                            }
                        }
                    }
                    MokaidButton {
                        objectName: "missionNewAgent"; visible: !!missions.customAgent.display_name
                        Layout.fillWidth: true; iconName: "plus"; text: missions.customSelected ? "New specialist selected" : "Create an agent for this mission"
                        highlighted: missions.customSelected; enabled: !missions.busy && !missions.launchUncertain
                        onClicked: {
                            missions.selectCustomAgent()
                            Qt.callLater(root.focusCustomAgent)
                        }
                    }
                    ColumnLayout {
                        id: customFields
                        visible: missions.customSelected; Layout.fillWidth: true; spacing: 10
                        MokaidLabel { text: "Meet your new teammate"; font.pixelSize: 17; font.weight: Font.DemiBold }
                        MokaidLabel { text: "We’ve prepared a role from your brief. Make it yours before creating the agent."; color: Theme.secondary; Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: 12 }
                        MokaidLabel { text: "Name"; color: Theme.secondary; font.pixelSize: 12 }
                        MokaidTextField { id: agentName; objectName: "missionAgentName"; Layout.fillWidth: true; text: missions.customAgent.display_name || ""; maximumLength: 100; enabled: !missions.busy && !missions.launchUncertain; Accessible.name: "New agent name"; onTextEdited: missions.configureCustomAgent(text, agentRole.text) }
                        MokaidLabel { text: "Role"; color: Theme.secondary; font.pixelSize: 12 }
                        MokaidTextField { id: agentRole; objectName: "missionAgentRole"; Layout.fillWidth: true; text: missions.customAgent.role_title || ""; maximumLength: 150; enabled: !missions.busy && !missions.launchUncertain; Accessible.name: "New agent role"; onTextEdited: missions.configureCustomAgent(agentName.text, text) }
                        MokaidLabel { Layout.fillWidth: true; text: (missions.customAgent.skills || []).map(function(skill) { return typeof skill === "string" ? skill : skill.name || "" }).join(" · "); visible: text.length > 0; color: Theme.muted; wrapMode: Text.Wrap; font.pixelSize: 12 }
                        MokaidLabel { text: "Working instructions · optional"; color: Theme.secondary; font.pixelSize: 12 }
                        MokaidTextArea { id: agentInstructions; Layout.fillWidth: true; Layout.preferredHeight: 100; text: missions.customAgent.instructions || ""; enabled: !missions.busy && !missions.launchUncertain; placeholderText: "How should this teammate work with you?"; wrapMode: TextEdit.Wrap; Accessible.name: "New agent working instructions"; onTextChanged: if (activeFocus && text !== (missions.customAgent.instructions || "")) missions.configureCustomAgent(agentName.text, agentRole.text, text) }
                    }
                    Repeater {
                        model: missions.grants
                        CheckBox {
                            required property var modelData
                            Layout.fillWidth: true; text: "Allow this agent to use " + (modelData.name || modelData.title || "this integration")
                            checked: modelData.selected === true; enabled: !missions.busy && !missions.launchUncertain
                            onToggled: missions.setGrant(modelData.id, checked)
                        }
                    }
                    RowLayout {
                        Layout.fillWidth: true; spacing: 10; Layout.topMargin: 6
                        MokaidIcon { name: "shield"; color: Theme.success; size: 18 }
                        MokaidLabel { Layout.fillWidth: true; text: "The agent checks its output before delivery. Complex work gets more time; straightforward work stays focused."; color: Theme.secondary; wrapMode: Text.Wrap; font.pixelSize: 12 }
                    }
                    MokaidLabel { Layout.fillWidth: true; visible: missions.capabilityWarning.length > 0; text: missions.capabilityWarning; color: Theme.warning; wrapMode: Text.Wrap; font.pixelSize: 12 }
                }
                ColumnLayout {
                    visible: root.delivered; Layout.fillWidth: true; spacing: 20
                    Layout.topMargin: 24
                    MokaidIcon { name: "tasks"; size: 52; color: Theme.success; Layout.alignment: Qt.AlignHCenter }
                    MokaidLabel { Layout.fillWidth: true; text: (missions.result.agent || {}).display_name || "Your agent"; font.pixelSize: 27; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap }
                    MokaidLabel { Layout.fillWidth: true; text: (missions.result.task || {}).title || "Mission assigned"; color: Theme.secondary; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap }
                    MokaidLabel { Layout.fillWidth: true; text: "You can keep working. We’ll notify you when the result is ready or your input is needed."; color: Theme.secondary; wrapMode: Text.Wrap; horizontalAlignment: Text.AlignHCenter }
                    MokaidButton { id: followMission; Layout.alignment: Qt.AlignHCenter; text: "Follow this mission"; iconName: "arrow-right"; highlighted: true; onClicked: missions.viewTask() }
                    MokaidButton { Layout.alignment: Qt.AlignHCenter; text: "Start another mission"; onClicked: { missions.reset(); missions.begin() } }
                }
            }
        }
        ColumnLayout {
            Layout.fillWidth: true; spacing: 12
            MokaidLabel { objectName: "missionError"; Layout.fillWidth: true; visible: missions.error.length > 0; text: missions.error; color: Theme.warning; wrapMode: Text.Wrap; Accessible.role: Accessible.AlertMessage }
            MokaidLabel { Layout.fillWidth: true; visible: !session.online; text: "You’re offline. Keep writing; reconnect to upload files and start the mission."; color: Theme.warning; wrapMode: Text.Wrap }
            RowLayout {
                Layout.fillWidth: true; visible: !root.delivered; spacing: 12
                MokaidButton { text: root.reviewing ? "Edit brief" : "Keep for later"; quiet: true; enabled: !missions.busy && !missions.launchUncertain; onClicked: root.reviewing ? missions.edit() : missions.close() }
                Item { Layout.fillWidth: true }
                BusyIndicator { running: missions.busy; visible: running; Layout.preferredWidth: 28; Layout.preferredHeight: 28 }
                MokaidButton {
                    id: continueButton
                    objectName: "missionContinue"; highlighted: true; iconName: "arrow-right"
                    text: missions.step === "analyzing" ? "Finding the right fit…" : missions.step === "launching" ? "Starting…" : missions.launchUncertain ? "Check launch & retry" : root.reviewing ? (missions.customSelected ? "Create & start" : "Start mission") : "Find my agent"
                    enabled: session.online && !missions.busy && (root.reviewing ? missions.canLaunch : missions.instruction.trim().length > 0 || missions.attachments.length > 0)
                    onClicked: root.reviewOrLaunch()
                }
            }
        }
    }
    DropArea {
        id: drop; anchors.fill: parent; enabled: !root.reviewing && !root.delivered && !missions.busy
        onEntered: function(drag) { drag.accepted = drag.hasUrls }
        onDropped: function(event) { if (event.hasUrls) { missions.addFiles(event.urls); event.acceptProposedAction() } }
    }
    FileDialog { id: filePicker; title: "Add mission files"; fileMode: FileDialog.OpenFiles; nameFilters: ["All files (*)"]; onAccepted: missions.addFiles(selectedFiles) }
}
