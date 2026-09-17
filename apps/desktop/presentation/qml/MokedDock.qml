import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root
    required property var controller
    required property var voiceController
    property bool signedIn: false
    property bool reducedMotion: false
    property bool animated: true
    property bool expanded: false
    property bool voiceEnabled: false
    property bool voiceSession: false
    property int currentTab: 0
    property int unread: 0
    property string announcement: ""
    property var previousFocus: null
    readonly property string voiceState: voiceController.state
    readonly property bool recording: voiceState === "listening"
    readonly property bool processingAudio: voiceState === "transcribing" || voiceState === "synthesizing"
    readonly property bool speaking: voiceState === "speaking"
    readonly property bool audioActive: recording || processingAudio || speaking
    readonly property string mascotMode: recording ? "listening" : speaking ? "speaking" : controller.busy || processingAudio ? "thinking" : activeMissions > 0 ? "working" : "idle"
    readonly property int activeMissions: controller.missions.filter(function(m) { return ["completed", "failed", "canceled", "cancelled"].indexOf(m.status) < 0 }).length
    readonly property string status: !signedIn ? qsTr("Votre copilote, à vos côtés") : recording ? qsTr("Je vous écoute…") : voiceState === "transcribing" ? qsTr("Je transcris votre message…") : voiceState === "synthesizing" ? qsTr("Je prépare la voix…") : speaking ? qsTr("Moked vous répond") : controller.busy ? qsTr("Je réfléchis à votre demande…") : !controller.ready ? qsTr("Hors ligne · brouillon conservé") : activeMissions > 0 ? qsTr("%1 mission(s) en cours").arg(activeMissions) : qsTr("Prêt à vous aider")
    signal missionPrepared()

    function show() {
        if (!expanded) previousFocus = root.Window.window ? root.Window.window.activeFocusItem : null
        expanded = true
        unread = 0
        controller.refresh()
        Qt.callLater(function() { composer.forceActiveFocus() })
    }
    function hide() {
        expanded = false
        voiceSession = false
        voiceController.cancel()
        if (previousFocus && previousFocus.forceActiveFocus) previousFocus.forceActiveFocus()
        else launcher.forceActiveFocus()
    }
    function send() {
        if (!controller.ready || controller.busy || !controller.draft.trim().length) return
        voiceController.cancel()
        currentTab = 0
        controller.sendMessage(controller.draft, controller.language)
    }
    function microphone() {
        show()
        currentTab = 0
        if (recording) { voiceController.stopListening(); return }
        if (processingAudio) { voiceSession = false; voiceController.cancel(); return }
        if (!voiceController.ready) { voiceSettings.open(); return }
        voiceSession = true
        voiceEnabled = true
        voiceController.startListening()
    }
    function missionStatus(value) {
        const names = { to_do: qsTr("À faire"), pending: qsTr("En attente"), queued: qsTr("En attente"), waiting: qsTr("En attente"), in_progress: qsTr("En cours"), running: qsTr("En cours"), assigned: qsTr("Assignée"), completed: qsTr("Terminée"), failed: qsTr("À vérifier"), canceled: qsTr("Annulée"), cancelled: qsTr("Annulée"), waiting_input: qsTr("Votre réponse est attendue"), awaiting_input: qsTr("Votre réponse est attendue"), review: qsTr("En vérification"), in_review: qsTr("À valider"), overdue: qsTr("En retard"), blocked: qsTr("Bloquée") }
        return names[value] || qsTr("État indisponible")
    }
    function resetView() { hide(); unread = 0; announcement = ""; voiceEnabled = false }
    onSignedInChanged: if (!signedIn) resetView()
    Connections {
        target: root.controller
        function onAssistantReplied(text, language) {
            if (!root.expanded) { root.unread += 1; root.announcement = text }
            if (root.voiceEnabled && root.expanded) root.voiceController.speak(text, language)
            Qt.callLater(function() { messages.positionViewAtEnd() })
        }
    }
    Connections {
        target: root.voiceController
        function onTranscribed(text, language) {
            if (!root.voiceSession) return
            root.voiceSession = false
            root.controller.language = language
            root.controller.draft = root.controller.draft.trim().length ? root.controller.draft + "\n" + text : text
            composer.forceActiveFocus()
        }
    }

    Rectangle {
        id: panel
        objectName: "mokedPanel"
        anchors.right: parent.right; anchors.bottom: parent.bottom
        anchors.rightMargin: 24; anchors.bottomMargin: 90
        width: Math.min(448, root.width - 32)
        height: Math.min(658, root.height - 120)
        radius: 20; color: Theme.surface; border.color: Theme.selectedBorder
        visible: opacity > 0
        opacity: root.expanded ? 1 : 0
        enabled: root.expanded
        transform: Translate { y: root.expanded ? 0 : 12; Behavior on y { NumberAnimation { duration: root.reducedMotion ? 0 : 230; easing.type: Easing.OutCubic } } }
        Behavior on opacity { NumberAnimation { duration: root.reducedMotion ? 0 : 160 } }
        Keys.onEscapePressed: function(event) { root.hide(); event.accepted = true }
        // Consume clicks on the floating surface without blocking the workspace outside it.
        MouseArea { anchors.fill: parent; onPressed: function(mouse) { mouse.accepted = true } }
        ColumnLayout {
            anchors.fill: parent; anchors.margins: 18; spacing: 12
            RowLayout {
                Layout.fillWidth: true; spacing: 12
                Rectangle {
                    Layout.preferredWidth: 44; Layout.preferredHeight: 44; radius: 14
                    color: Theme.selected
                    MokaidIcon { anchors.centerIn: parent; name: "moked"; size: 27; color: "#d9c9ff" }
                }
                ColumnLayout {
                    spacing: 3; Layout.fillWidth: true
                    MokaidLabel { text: "Moked"; font.pixelSize: 21; font.weight: Font.Bold }
                    MokaidLabel { Layout.fillWidth: true; text: root.status; font.pixelSize: 11; color: root.recording ? Theme.success : Theme.secondary; elide: Text.ElideRight; Accessible.role: Accessible.StatusBar }
                }
                MokaidIconButton { iconName: "settings"; hint: qsTr("Voix et modèles locaux"); subtle: true; implicitWidth: 34; onClicked: voiceSettings.open() }
                MokaidIconButton { objectName: "mokedClose"; iconName: "minus"; hint: qsTr("Réduire Moked"); subtle: true; implicitWidth: 34; onClicked: root.hide() }
            }
            RowLayout {
                spacing: 6; Layout.fillWidth: true
                Repeater {
                    model: [qsTr("Conversation"), qsTr("Missions") + (root.activeMissions ? " · " + root.activeMissions : "")]
                    AbstractButton {
                        required property int index
                        required property string modelData
                        objectName: index === 0 ? "mokedChatTab" : "mokedMissionsTab"
                        Layout.fillWidth: true; implicitHeight: 36; hoverEnabled: true
                        Accessible.name: modelData; Accessible.role: Accessible.PageTab; Accessible.description: root.currentTab === index ? qsTr("Onglet actif") : ""
                        onClicked: { root.currentTab = index; if (index === 1) root.controller.refresh() }
                        background: Rectangle { radius: 9; color: root.currentTab === index ? Theme.selected : parent.hovered ? Theme.hover : "transparent"; border.color: parent.visualFocus ? Theme.focusBorder : "transparent" }
                        contentItem: MokaidLabel { text: parent.modelData; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; color: root.currentTab === parent.index ? Theme.text : Theme.secondary; font.weight: Font.DemiBold; font.pixelSize: 12 }
                    }
                }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.divider }
            StackLayout {
                Layout.fillWidth: true; Layout.fillHeight: true; currentIndex: root.currentTab
                Item {
                    ColumnLayout {
                        anchors.fill: parent; spacing: 10
                        Item {
                            Layout.fillWidth: true; Layout.fillHeight: true
                            ColumnLayout {
                                visible: root.controller.messages.length === 0 && !root.audioActive
                                anchors.centerIn: parent; width: parent.width - 12; spacing: 14
                                MokedMascot { Layout.alignment: Qt.AlignHCenter; Layout.preferredWidth: panel.height < 600 ? 88 : 116; Layout.preferredHeight: panel.height < 600 ? 90 : 118; mode: root.mascotMode; reducedMotion: root.reducedMotion; animated: root.animated && root.expanded }
                                MokaidLabel { Layout.fillWidth: true; text: qsTr("Une idée. Une équipe.\nOn s’en occupe."); font.pixelSize: 23; font.weight: Font.DemiBold; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap }
                                MokaidLabel { Layout.fillWidth: true; text: root.signedIn ? qsTr("Décrivez votre objectif. Je vous aide à préparer les missions et à suivre les livrables de vos agents.") : qsTr("Connectez votre espace de travail pour discuter et confier une mission à vos agents."); horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap; color: Theme.secondary; font.pixelSize: 12 }
                            }
                            ListView {
                                id: messages; objectName: "mokedMessages"
                                anchors.fill: parent; model: root.controller.messages; spacing: 18; clip: true
                                visible: !root.audioActive && count > 0
                                boundsBehavior: Flickable.StopAtBounds
                                onCountChanged: Qt.callLater(function() { messages.positionViewAtEnd() })
                                onHeightChanged: Qt.callLater(function() { messages.positionViewAtEnd() })
                                onContentHeightChanged: Qt.callLater(function() { messages.positionViewAtEnd() })
                                delegate: ColumnLayout {
                                    required property var modelData
                                    width: messages.width - 8; spacing: 6
                                    readonly property bool member: modelData.role === "user"
                                    MokaidLabel { text: parent.member ? qsTr("Vous") : "Moked"; color: parent.member ? Theme.secondary : Theme.primary; font.weight: Font.DemiBold; font.pixelSize: 11; Layout.alignment: parent.member ? Qt.AlignRight : Qt.AlignLeft }
                                    Rectangle {
                                        Layout.fillWidth: true
                                        Layout.leftMargin: parent.member ? 26 : 0
                                        implicitHeight: messageText.implicitHeight + (parent.member ? 22 : 6)
                                        radius: 12; color: parent.member ? Theme.selected : "transparent"
                                        TextEdit {
                                            id: messageText; anchors.fill: parent; anchors.margins: parent.parent.member ? 11 : 3
                                            text: modelData.body || ""; textFormat: TextEdit.PlainText; color: Theme.text
                                            readOnly: true; selectByMouse: true; wrapMode: TextEdit.Wrap
                                            font.family: Theme.fontFamily; font.pixelSize: 13
                                            selectionColor: Theme.selection; selectedTextColor: Theme.text
                                            Accessible.name: (parent.parent.member ? qsTr("Vous : ") : "Moked : ") + text
                                        }
                                    }
                                    MokaidButton { visible: !!modelData.task_id; text: qsTr("Ouvrir la mission"); iconName: "arrow-right"; onClicked: { root.controller.reviewMission(modelData.task_id); root.hide() } }
                                }
                                ScrollBar.vertical: ScrollBar { }
                            }
                            ColumnLayout {
                                visible: root.audioActive
                                anchors.centerIn: parent; width: parent.width; spacing: 16
                                MokedMascot { Layout.alignment: Qt.AlignHCenter; Layout.preferredWidth: panel.height < 600 ? 130 : 170; Layout.preferredHeight: panel.height < 600 ? 130 : 170; mode: root.mascotMode; reducedMotion: root.reducedMotion; animated: root.animated; audioLevel: root.voiceController.level || 0 }
                                MokaidLabel { text: root.status; font.pixelSize: 21; font.weight: Font.DemiBold; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap }
                                MokaidLabel { text: root.recording ? qsTr("Parlez naturellement, dans votre langue.\nVous pourrez relire le texte avant l’envoi.") : root.processingAudio ? qsTr("La transcription reste sur cet ordinateur.") : qsTr("Vous pouvez interrompre la lecture à tout moment."); Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap; color: Theme.secondary; font.pixelSize: 12 }
                                MokaidButton { Layout.alignment: Qt.AlignHCenter; text: root.recording ? qsTr("Terminer et transcrire") : qsTr("Arrêter"); iconName: "stop"; onClicked: root.recording ? root.voiceController.stopListening() : root.voiceController.cancel() }
                            }
                        }
                        MokaidLabel { visible: root.controller.busy; Layout.fillWidth: true; text: qsTr("Moked prépare sa réponse…"); color: Theme.primary; font.pixelSize: 12; Accessible.role: Accessible.StatusBar }
                        Rectangle {
                            visible: !!root.controller.pendingInstruction && !root.audioActive
                            Layout.fillWidth: true; implicitHeight: proposal.implicitHeight + 24; radius: 12; color: Theme.selected
                            ColumnLayout {
                                id: proposal; anchors.fill: parent; anchors.margins: 12; spacing: 8
                                MokaidLabel { text: qsTr("Prête à être confiée à un agent"); font.weight: Font.DemiBold; font.pixelSize: 12; Layout.fillWidth: true }
                                MokaidLabel { text: root.controller.pendingInstruction; color: Theme.secondary; font.pixelSize: 12; maximumLineCount: 2; elide: Text.ElideRight; wrapMode: Text.Wrap; Layout.fillWidth: true }
                                MokaidButton { objectName: "mokedPrepareMission"; text: qsTr("Préparer la mission"); iconName: "arrow-right"; highlighted: true; Layout.fillWidth: true; enabled: root.controller.ready && !root.controller.busy; onClicked: { root.controller.prepareMission(); root.hide(); root.missionPrepared() } }
                            }
                        }
                    }
                }
                Item {
                    ListView {
                        id: missionList; anchors.fill: parent; model: root.controller.missions; spacing: 10; clip: true; boundsBehavior: Flickable.StopAtBounds
                        delegate: Rectangle {
                            required property var modelData
                            width: missionList.width - 8; implicitHeight: missionBody.implicitHeight + 26; radius: 12; color: Theme.control; border.color: Theme.divider
                            ColumnLayout {
                                id: missionBody; anchors.fill: parent; anchors.margins: 13; spacing: 9
                                RowLayout {
                                    Layout.fillWidth: true
                                    Rectangle { width: 6; height: 6; radius: 3; color: modelData.status === "completed" ? Theme.success : modelData.status === "failed" || modelData.status === "blocked" ? Theme.warning : Theme.primary }
                                    MokaidLabel { text: root.missionStatus(modelData.status); font.pixelSize: 11; color: Theme.secondary; Layout.fillWidth: true }
                                    MokaidLabel { text: typeof modelData.progress_percent === "number" ? Math.round(modelData.progress_percent) + "%" : ""; color: Theme.muted; font.pixelSize: 11 }
                                }
                                MokaidLabel { Layout.fillWidth: true; text: modelData.title || qsTr("Mission"); font.weight: Font.DemiBold; wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight }
                                MokaidLabel { Layout.fillWidth: true; visible: text.length > 0; text: modelData.assigned_agent_name || ""; color: Theme.secondary; font.pixelSize: 12; elide: Text.ElideRight }
                                RowLayout {
                                    Layout.fillWidth: true
                                    MokaidButton { text: (modelData.artifacts || []).length > 0 ? qsTr("Voir le livrable") : qsTr("Voir la mission"); iconName: "arrow-right"; Layout.fillWidth: true; onClicked: { root.controller.reviewMission(modelData.id); root.hide() } }
                                    MokaidIconButton { visible: ["running", "in_progress"].indexOf(modelData.status) >= 0; iconName: "stop"; hint: qsTr("Arrêter la mission"); enabled: root.controller.ready; onClicked: { stopMission.taskId = modelData.id; stopMission.open() } }
                                }
                            }
                        }
                        ScrollBar.vertical: ScrollBar { }
                    }
                    ColumnLayout {
                        visible: missionList.count === 0; anchors.centerIn: parent; width: parent.width - 32; spacing: 14
                        MokaidIcon { Layout.alignment: Qt.AlignHCenter; name: "tasks"; size: 36; color: Theme.primary }
                        MokaidLabel { text: root.controller.refreshing ? qsTr("Chargement des missions…") : qsTr("Vos missions, au même endroit"); font.pixelSize: 20; font.weight: Font.DemiBold; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap }
                        MokaidLabel { text: qsTr("Les missions de votre espace, leur avancement et les livrables apparaîtront ici."); color: Theme.secondary; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap }
                        MokaidButton { text: qsTr("Parlons de votre objectif"); Layout.alignment: Qt.AlignHCenter; onClicked: { root.currentTab = 0; composer.forceActiveFocus() } }
                    }
                }
            }
            MokaidLabel { objectName: "mokedError"; visible: text.length > 0; text: root.controller.error || root.voiceController.error; Layout.fillWidth: true; color: Theme.warning; wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight; font.pixelSize: 12; Accessible.role: Accessible.AlertMessage }
            ColumnLayout {
                visible: root.currentTab === 0 && !root.audioActive; Layout.fillWidth: true; spacing: 8
                ScrollView {
                    Layout.fillWidth: true; Layout.preferredHeight: 88
                    MokaidTextArea {
                        id: composer; objectName: "mokedComposer"
                        text: root.controller.draft; placeholderText: root.signedIn ? qsTr("Que souhaitez-vous accomplir ?") : qsTr("Connectez-vous pour discuter…")
                        enabled: root.signedIn && !root.recording && !root.processingAudio
                        wrapMode: TextEdit.Wrap; Accessible.name: qsTr("Message à Moked")
                        onTextChanged: if (root.controller.draft !== text) root.controller.draft = text
                        Keys.onPressed: function(event) {
                            if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !(event.modifiers & Qt.ShiftModifier)) { root.send(); event.accepted = true }
                        }
                    }
                }
                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                    MokaidIconButton { objectName: "mokedMicrophone"; iconName: root.recording ? "stop" : "microphone"; hint: root.recording ? qsTr("Terminer la dictée") : qsTr("Dicter un message"); enabled: root.signedIn && !root.controller.busy; onClicked: root.microphone() }
                    MokaidIconButton { iconName: root.voiceEnabled ? "speaker" : "speaker-off"; hint: root.voiceEnabled ? qsTr("Désactiver les réponses vocales") : qsTr("Lire les réponses à voix haute"); onClicked: { root.voiceEnabled = !root.voiceEnabled; if (!root.voiceEnabled) root.voiceController.cancel() } }
                    MokaidLabel { Layout.fillWidth: true; text: qsTr("Entrée pour envoyer"); font.pixelSize: 10; color: Theme.muted; wrapMode: Text.Wrap }
                    MokaidButton { objectName: "mokedSend"; text: qsTr("Envoyer"); iconName: "send"; highlighted: true; enabled: root.controller.ready && !root.controller.busy && !root.recording && !root.processingAudio && root.controller.draft.trim().length > 0; onClicked: root.send() }
                }
            }
        }
    }

    Item {
        anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.rightMargin: 24; anchors.bottomMargin: 18
        width: 194; height: root.expanded ? 54 : 192
        MokedMascot {
            anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.rightMargin: 13; anchors.bottomMargin: 42
            width: 140; height: 146; visible: !root.expanded
            mode: root.mascotMode; reducedMotion: root.reducedMotion; animated: root.animated
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.show(); Accessible.ignored: true }
        }
        Rectangle {
            visible: root.unread > 0 && !root.expanded
            anchors.right: parent.left; anchors.bottom: parent.bottom; anchors.bottomMargin: 68
            width: Math.min(230, Math.max(130, root.width - 240)); height: updateText.implicitHeight + 28; radius: 14; color: Theme.surface; border.color: Theme.selectedBorder
            MokaidLabel { id: updateText; anchors.fill: parent; anchors.margins: 14; text: root.announcement; maximumLineCount: 3; elide: Text.ElideRight; wrapMode: Text.Wrap; font.pixelSize: 12 }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.show() }
        }
        RowLayout {
            anchors.right: parent.right; anchors.bottom: parent.bottom; spacing: 8
            MokaidIconButton { iconName: root.recording ? "stop" : "microphone"; hint: qsTr("Parler à Moked"); enabled: root.signedIn && !root.controller.busy; onClicked: root.microphone() }
            AbstractButton {
                id: launcher; objectName: "mokedLauncher"
                implicitWidth: 130; implicitHeight: 46; hoverEnabled: true
                Accessible.name: root.expanded ? qsTr("Réduire Moked") : qsTr("Ouvrir Moked, votre orchestrateur")
                onClicked: root.expanded ? root.hide() : root.show()
                background: Rectangle { radius: 15; color: launcher.hovered ? "#302448" : "#1f1932"; border.color: launcher.visualFocus ? Theme.focusBorder : "#68528f" }
                contentItem: RowLayout {
                    spacing: 8
                    MokaidIcon { name: "moked"; size: 19; color: Theme.primary; Layout.leftMargin: 14 }
                    MokaidLabel { text: "Moked"; font.weight: Font.DemiBold; Layout.fillWidth: true }
                    MokaidIcon { name: root.expanded ? "chevron-down" : "chevron-up"; size: 14; Layout.rightMargin: 12 }
                }
            }
        }
    }
    MokaidDialog {
        id: voiceSettings; objectName: "mokedVoiceSettings"
        anchors.centerIn: parent; modal: true; width: Math.min(460, root.width - 40); title: qsTr("La voix de Moked"); standardButtons: Dialog.Close
        ColumnLayout {
            width: parent.width; spacing: 16
            MokaidLabel { Layout.fillWidth: true; text: qsTr("Parlez dans votre langue."); font.pixelSize: 23; font.weight: Font.DemiBold; wrapMode: Text.Wrap }
            MokaidLabel { Layout.fillWidth: true; text: qsTr("La reconnaissance vocale s’exécute sur cet ordinateur. Le texte est envoyé à votre espace Mokaid lorsque vous appuyez sur Envoyer."); color: Theme.secondary; wrapMode: Text.Wrap }
            MokaidLabel { Layout.fillWidth: true; text: root.voiceController.ready ? qsTr("Whisper multilingue et Kokoro sont prêts.") : root.voiceState === "preparing" ? qsTr("Vérification des modèles inclus dans l’application…") : qsTr("Le pack vocal est absent ou incomplet. Utilisez une version de Mokaid incluant les modèles vocaux."); wrapMode: Text.Wrap; color: root.voiceController.ready ? Theme.success : Theme.secondary }
            ProgressBar { Layout.fillWidth: true; visible: root.voiceState === "preparing"; indeterminate: true }
            MokaidButton { Layout.fillWidth: true; visible: !root.voiceController.ready; text: qsTr("Vérifier les modèles locaux"); highlighted: true; enabled: root.voiceState !== "preparing"; onClicked: root.voiceController.setup() }
            MokaidLabel { Layout.fillWidth: true; text: qsTr("Kokoro lit les langues compatibles. Pour les autres, Moked utilise une voix système installée, si elle existe. Sinon, la réponse reste écrite."); color: Theme.muted; wrapMode: Text.Wrap; font.pixelSize: 12 }
            MokaidLabel { Layout.fillWidth: true; text: root.voiceController.error; visible: text.length > 0; color: Theme.warning; wrapMode: Text.Wrap }
        }
    }
    MokaidDialog {
        id: stopMission; property string taskId: ""
        anchors.centerIn: parent; title: qsTr("Arrêter cette mission ?"); modal: true; width: 390; standardButtons: Dialog.Ok | Dialog.Cancel
        MokaidLabel { width: parent.width; text: qsTr("L’exécution de l’agent sera interrompue. Les livrables déjà enregistrés resteront accessibles."); wrapMode: Text.Wrap }
        onAccepted: root.controller.cancelMission(taskId)
    }
}
