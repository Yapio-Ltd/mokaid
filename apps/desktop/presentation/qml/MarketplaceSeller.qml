pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root
    objectName: "marketplaceSeller"
    required property var controller
    property string listingFilter: "all"
    property int wizardStep: 0
    readonly property color edge: "#25283d"
    readonly property color surface: "#11131e"
    readonly property var eligibleRows: (controller.sortedMineRows || []).filter(function(row) { return !!row.eligible && !row.listing })
    readonly property var filteredRows: (controller.sortedMineRows || []).filter(function(row) {
        if (root.listingFilter === "all") return true
        if (root.listingFilter === "ready") return !!row.eligible && !row.listing
        if (root.listingFilter === "training") return !row.eligible && !row.listing
        if (root.listingFilter === "paused") return row.listing && row.listing.status === "paused"
        return row.listing && row.listing.mode === root.listingFilter
    })
    readonly property bool connectKnown: controller.earningsData.connect_ready !== undefined || !!(controller.earningsData.meta && controller.earningsData.meta.connect_ready !== undefined)
    readonly property bool connectReady: controller.earningsData.connect_ready !== undefined ? !!controller.earningsData.connect_ready : !!(controller.earningsData.meta && controller.earningsData.meta.connect_ready)
    readonly property bool canPublish: !!controller.publishRow.eligible && !controller.publishRow.listing && controller.priceValid && String(controller.publishTitle || "").trim().length > 0 && (!connectKnown || connectReady)
    readonly property bool stepValid: wizardStep === 0 ? !!controller.publishRow.eligible && String(controller.publishTitle || "").trim().length > 0 : wizardStep === 2 ? controller.priceValid : true
    readonly property var selectedAgent: controller.publishAgent || ({})

    function countFor(filter) {
        return (controller.mineRows || []).filter(function(row) {
            if (filter === "all") return true
            if (filter === "ready") return !!row.eligible && !row.listing
            if (filter === "training") return !row.eligible && !row.listing
            if (filter === "paused") return row.listing && row.listing.status === "paused"
            return row.listing && row.listing.mode === filter
        }).length
    }
    function startListing() {
        if (!eligibleRows.length) return
        controller.openOffer(eligibleRows[0].agent.id, "sale")
    }
    function priceText(listing) {
        if (!listing) return "—"
        return controller.money(listing.price_cents, listing.currency)
            + (listing.mode === "rent" ? listing.rent_billing === "subscription" ? " / mo" : " / " + listing.fixed_days + "d" : "")
    }
    function statusText(row) {
        if (row.listing) return row.listing.status === "paused" ? "Paused" : "Active"
        return row.eligible ? "Ready to list" : "Training"
    }
    Connections {
        target: root.controller
        function onPublishAgentIdChanged() { root.wizardStep = 0 }
    }

    component Pill: AbstractButton {
        id: pill
        property bool selected: false
        implicitWidth: pillLabel.implicitWidth + 24
        implicitHeight: 34
        hoverEnabled: true
        background: Rectangle {
            radius: 7
            color: pill.selected ? "#8035e7" : pill.hovered ? "#1c2032" : "#10131f"
            border.color: pill.visualFocus ? Theme.focusBorder : pill.selected ? "#a361ff" : root.edge
        }
        contentItem: MokaidLabel {
            id: pillLabel
            text: pill.text
            font.pixelSize: 11
            color: pill.selected ? "#ffffff" : "#b6c0dc"
            horizontalAlignment: Text.AlignHCenter
        }
    }
    component PrimaryButton: MokaidButton {
        id: primary
        implicitHeight: 38
        highlighted: true
        font.pixelSize: 12
        background: Rectangle {
            radius: 7
            opacity: primary.enabled ? 1 : .45
            gradient: Gradient {
                GradientStop { position: 0; color: primary.down ? "#7731d7" : primary.hovered ? "#a44cff" : "#9744fa" }
                GradientStop { position: 1; color: primary.down ? "#6021c0" : "#7925ef" }
            }
            border.color: primary.visualFocus ? Theme.focusBorder : "#a057fb"
        }
    }
    component Section: Rectangle {
        radius: 10
        color: root.surface
        border.color: root.edge
    }
    component FieldLabel: MokaidLabel {
        font.pixelSize: 11
        color: "#dce2f4"
        font.weight: Font.DemiBold
    }

    MarketplaceEarnings {
        anchors.fill: parent
        controller: root.controller
        visible: root.controller.tab === "earnings" && root.controller.screen !== "publish"
    }

    Flickable {
        id: listingsScroll
        anchors.fill: parent
        visible: root.controller.tab === "mine" && root.controller.screen !== "publish"
        contentWidth: width
        contentHeight: listingColumn.implicitHeight + 16
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
        ColumnLayout {
            id: listingColumn
            width: listingsScroll.width
            spacing: 16
            RowLayout {
                Layout.fillWidth: true
                ColumnLayout {
                    spacing: 3
                    Layout.fillWidth: true
                    MokaidLabel { text: "My listings"; font.pixelSize: 25; font.weight: Font.DemiBold }
                    MokaidLabel { text: "Manage the agents you are selling or renting."; color: Theme.secondary; font.pixelSize: 12 }
                }
                Item { Layout.fillWidth: true }
                PrimaryButton {
                    objectName: "marketplaceCreateListing"
                    text: "Create new listing"
                    enabled: !features.busy && root.eligibleRows.length > 0
                    onClicked: root.startListing()
                    ToolTip.visible: hovered && !enabled
                    ToolTip.text: "An available level " + root.controller.minLevel + " agent is required."
                }
            }
            Flow {
                Layout.fillWidth: true
                spacing: 7
                Repeater {
                    model: [{id:"all", label:"All agents"}, {id:"sale", label:"For sale"}, {id:"rent", label:"For rent"}, {id:"ready", label:"Ready to list"}, {id:"paused", label:"Paused"}, {id:"training", label:"Training"}]
                    Pill {
                        required property var modelData
                        text: modelData.label + " (" + root.countFor(modelData.id) + ")"
                        selected: root.listingFilter === modelData.id
                        onClicked: root.listingFilter = modelData.id
                    }
                }
            }
            Section {
                Layout.fillWidth: true
                implicitHeight: tableColumn.implicitHeight + 2
                ColumnLayout {
                    id: tableColumn
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 1
                    spacing: 0
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.leftMargin: 16
                        Layout.rightMargin: 16
                        Layout.preferredHeight: 38
                        spacing: 12
                        MokaidLabel { text: "Agent"; color: Theme.muted; font.pixelSize: 10; Layout.fillWidth: true; Layout.minimumWidth: 130 }
                        MokaidLabel { text: "Type"; color: Theme.muted; font.pixelSize: 10; Layout.preferredWidth: 65 }
                        MokaidLabel { text: "Price"; color: Theme.muted; font.pixelSize: 10; Layout.preferredWidth: 116 }
                        MokaidLabel { text: "Level"; color: Theme.muted; font.pixelSize: 10; Layout.preferredWidth: 46 }
                        MokaidLabel { text: "Knowledge"; color: Theme.muted; font.pixelSize: 10; Layout.preferredWidth: 64; visible: root.width > 790 }
                        MokaidLabel { text: "Status"; color: Theme.muted; font.pixelSize: 10; Layout.preferredWidth: 94 }
                        MokaidLabel { text: "Actions"; color: Theme.muted; font.pixelSize: 10; Layout.preferredWidth: 42; horizontalAlignment: Text.AlignHCenter }
                    }
                    Repeater {
                        model: root.filteredRows
                        delegate: Rectangle {
                            id: listingRow
                            required property var modelData
                            readonly property var agent: modelData.agent || ({})
                            Layout.fillWidth: true
                            implicitHeight: 66
                            color: listingHover.hovered ? "#171b2a" : "transparent"
                            HoverHandler { id: listingHover }
                            Rectangle { width: parent.width; height: 1; color: "#202338" }
                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 16
                                anchors.rightMargin: 16
                                spacing: 12
                                RowLayout {
                                    Layout.fillWidth: true
                                    Layout.minimumWidth: 130
                                    spacing: 10
                                    WorkforcePortrait { agent: root.controller.faceAgent(listingRow.agent); size: 35 }
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 2
                                        MokaidLabel {
                                            text: (listingRow.modelData.listing && listingRow.modelData.listing.title) || listingRow.agent.display_name || "Agent"
                                            Layout.fillWidth: true; elide: Text.ElideRight
                                            font.pixelSize: 12; font.weight: Font.DemiBold
                                        }
                                        MokaidLabel { text: root.controller.roleTitle(listingRow.agent) || "AI agent"; Layout.fillWidth: true; elide: Text.ElideRight; font.pixelSize: 10; color: Theme.muted }
                                    }
                                }
                                Item {
                                    Layout.preferredWidth: 65
                                    Layout.preferredHeight: 24
                                    Rectangle {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 62; height: 22; radius: 5
                                        color: listingRow.modelData.listing ? listingRow.modelData.listing.mode === "rent" ? "#102b27" : "#202144" : "transparent"
                                        border.color: listingRow.modelData.listing ? listingRow.modelData.listing.mode === "rent" ? "#226950" : "#4c4b91" : "transparent"
                                        MokaidLabel { anchors.centerIn: parent; text: listingRow.modelData.listing ? listingRow.modelData.listing.mode === "rent" ? "For rent" : "For sale" : "—"; font.pixelSize: 10; color: listingRow.modelData.listing && listingRow.modelData.listing.mode === "rent" ? "#91f0cf" : "#d2d1ff" }
                                    }
                                }
                                MokaidLabel { text: root.priceText(listingRow.modelData.listing); font.pixelSize: 11; Layout.preferredWidth: 116; elide: Text.ElideRight }
                                MokaidLabel { text: String(listingRow.modelData.level || listingRow.agent.level || 1); font.pixelSize: 11; Layout.preferredWidth: 46; color: listingRow.modelData.eligible ? Theme.text : Theme.warning }
                                MokaidLabel { text: String(listingRow.modelData.knowledge_item_count || 0); font.pixelSize: 11; Layout.preferredWidth: 64; visible: root.width > 790 }
                                Item {
                                    Layout.preferredWidth: 94
                                    Layout.preferredHeight: 24
                                    Rectangle {
                                        anchors.verticalCenter: parent.verticalCenter
                                        implicitWidth: statusLabel.implicitWidth + 14; height: 23; radius: 5
                                        color: listingRow.modelData.listing && listingRow.modelData.listing.status !== "paused" ? "#102b25" : "#1b1930"
                                        border.color: listingRow.modelData.listing && listingRow.modelData.listing.status !== "paused" ? "#268767" : "#423658"
                                        MokaidLabel { id: statusLabel; anchors.centerIn: parent; text: root.statusText(listingRow.modelData); font.pixelSize: 10; color: listingRow.modelData.listing && listingRow.modelData.listing.status !== "paused" ? "#80e8c3" : "#cec0ef" }
                                    }
                                }
                                MokaidButton {
                                    id: rowActions
                                    Layout.preferredWidth: 40
                                    Layout.preferredHeight: 30
                                    implicitWidth: 40
                                    iconName: "more"
                                    leftPadding: 11
                                    rightPadding: 11
                                    enabled: !features.busy && (!!listingRow.modelData.listing || !!listingRow.modelData.eligible)
                                    Accessible.name: "Actions for " + (listingRow.agent.display_name || "agent")
                                    onClicked: actionsMenu.openFor(rowActions)
                                    MokaidMenu {
                                        id: actionsMenu
                                        MokaidMenu.Entry { text: listingRow.modelData.listing && listingRow.modelData.listing.status === "paused" ? "Resume listing" : "Pause listing"; visible: !!listingRow.modelData.listing; enabled: visible && !features.busy; onTriggered: root.controller.toggleListing(listingRow.modelData.listing) }
                                        MokaidMenu.Entry { text: "Sell copies"; visible: !listingRow.modelData.listing && !!listingRow.modelData.eligible; enabled: visible && !features.busy; onTriggered: root.controller.openOffer(listingRow.agent.id, "sale") }
                                        MokaidMenu.Entry { text: "Rent out"; visible: !listingRow.modelData.listing && !!listingRow.modelData.eligible; enabled: visible && !features.busy; onTriggered: root.controller.openOffer(listingRow.agent.id, "rent") }
                                    }
                                }
                            }
                        }
                    }
                    ColumnLayout {
                        visible: root.filteredRows.length === 0
                        Layout.fillWidth: true
                        Layout.margins: 40
                        spacing: 10
                        MokaidIcon { name: "marketplace"; size: 30; color: "#a778f9"; Layout.alignment: Qt.AlignHCenter }
                        MokaidLabel { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: features.busy ? "Loading your agents…" : root.controller.mineRows.length ? "No agents in this view" : "Your marketplace starts here"; font.pixelSize: 16; font.weight: Font.DemiBold }
                        MokaidLabel { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: root.controller.mineRows.length ? "Choose another filter to see your agents." : "Train an AI agent to level " + root.controller.minLevel + " to publish your first listing."; wrapMode: Text.Wrap; font.pixelSize: 12; color: Theme.secondary }
                    }
                }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 9
                MokaidIcon { name: "shield"; size: 15; color: "#ab83ec" }
                MokaidLabel { Layout.fillWidth: true; text: root.controller.mineHint; font.pixelSize: 11; color: Theme.secondary; wrapMode: Text.Wrap }
            }
            Section {
                visible: root.connectKnown && !root.connectReady && root.controller.mineSummary.ready > 0
                Layout.fillWidth: true
                implicitHeight: payoutPrompt.implicitHeight + 28
                RowLayout {
                    id: payoutPrompt
                    anchors.fill: parent; anchors.margins: 14; spacing: 14
                    ColumnLayout {
                        Layout.fillWidth: true
                        MokaidLabel { text: "Set up your seller payouts"; font.weight: Font.DemiBold; font.pixelSize: 13 }
                        MokaidLabel { Layout.fillWidth: true; text: "Connect Stripe to receive payments and publish your agents."; color: Theme.secondary; font.pixelSize: 11; wrapMode: Text.Wrap }
                    }
                    MokaidButton { text: "Set up payouts"; implicitHeight: 34; font.pixelSize: 11; onClicked: root.controller.tab = "earnings" }
                }
            }
        }
    }

    Flickable {
        id: wizardScroll
        objectName: "offerPage"
        visible: root.controller.screen === "publish"
        anchors.fill: parent
        contentWidth: width
        contentHeight: wizardColumn.implicitHeight + 20
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
        ColumnLayout {
            id: wizardColumn
            width: wizardScroll.width
            spacing: 19
            MokaidButton { text: "Back to my listings"; iconName: "chevron-left"; implicitHeight: 28; quiet: true; leftPadding: 0; font.pixelSize: 11; enabled: !features.busy; onClicked: root.controller.closeOffer("mine") }
            RowLayout {
                Layout.fillWidth: true
                spacing: 24
                MokaidLabel { text: "Create a new listing"; font.pixelSize: root.width < 780 ? 20 : 24; font.weight: Font.DemiBold }
                Item { Layout.fillWidth: true }
                Repeater {
                    model: ["Basic info", "Details", "Pricing", "Review"]
                    AbstractButton {
                        id: stepButton
                        required property string modelData
                        required property int index
                        implicitWidth: stepContent.implicitWidth
                        implicitHeight: 32
                        enabled: index <= root.wizardStep
                        hoverEnabled: true
                        onClicked: root.wizardStep = index
                        Accessible.name: "Step " + (index + 1) + ": " + modelData
                        contentItem: RowLayout {
                            id: stepContent
                            spacing: 6
                            Rectangle {
                                implicitWidth: 21; implicitHeight: 21; radius: 11
                                color: root.wizardStep === stepButton.index ? "#883cf0" : "transparent"
                                border.color: stepButton.visualFocus ? Theme.focusBorder : root.wizardStep >= stepButton.index ? "#a963ff" : "#7480a0"
                                MokaidLabel { anchors.centerIn: parent; text: String(stepButton.index + 1); font.pixelSize: 9; color: root.wizardStep >= stepButton.index ? "#ffffff" : Theme.muted }
                            }
                            MokaidLabel { text: stepButton.modelData; visible: root.width >= 760 || root.wizardStep === stepButton.index; font.pixelSize: 10; color: root.wizardStep === stepButton.index ? "#d7b9ff" : Theme.muted }
                        }
                    }
                }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 16
                Section {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignTop
                    implicitHeight: formColumn.implicitHeight + 34
                    ColumnLayout {
                        id: formColumn
                        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 17
                        spacing: 14
                        MokaidLabel { text: ["Basic information", "Agent details", "Set your price", "Review your listing"][root.wizardStep]; font.pixelSize: 14; font.weight: Font.DemiBold }
                        ColumnLayout {
                            visible: root.wizardStep === 0
                            Layout.fillWidth: true; spacing: 7
                            FieldLabel { text: "Agent" }
                            MokaidComboBox {
                                id: agentPicker
                                objectName: "marketplacePublishAgent"
                                Layout.fillWidth: true; implicitHeight: 38; font.pixelSize: 12
                                model: root.eligibleRows.map(function(row) { return row.agent.display_name || "Agent" })
                                currentIndex: root.eligibleRows.findIndex(function(row) { return row.agent.id === root.controller.publishAgentId })
                                onActivated: { const row = root.eligibleRows[index]; if (row) root.controller.openOffer(row.agent.id, root.controller.publishMode) }
                                Accessible.name: "Choose an eligible agent"
                            }
                            FieldLabel { text: "Name"; Layout.topMargin: 5 }
                            MokaidTextField {
                                objectName: "marketplacePublishTitle"
                                Layout.fillWidth: true; implicitHeight: 38; font.pixelSize: 12
                                text: root.controller.publishTitle || ""
                                placeholderText: "Give your listing a name"
                                maximumLength: 160
                                onTextEdited: root.controller.publishTitle = text
                                Accessible.name: "Listing name"
                            }
                            FieldLabel { text: "Short description"; Layout.topMargin: 5 }
                            MokaidTextArea {
                                objectName: "marketplacePublishDescription"
                                Layout.fillWidth: true; Layout.preferredHeight: 100; font.pixelSize: 12
                                text: root.controller.publishDescription || ""
                                placeholderText: "Describe what your agent can help with…"
                                wrapMode: TextEdit.Wrap
                                onTextChanged: if (activeFocus) root.controller.publishDescription = text
                                Accessible.name: "Listing description"
                            }
                            RowLayout {
                                Layout.fillWidth: true; spacing: 12
                                ColumnLayout {
                                    Layout.fillWidth: true; spacing: 7
                                    FieldLabel { text: "Category" }
                                    Rectangle {
                                        Layout.fillWidth: true; implicitHeight: 38; radius: 7; color: "#0d101b"; border.color: root.edge
                                        MokaidLabel { anchors.fill: parent; anchors.margins: 11; text: root.controller.titleCase(root.selectedAgent.department || root.controller.roleTitle(root.selectedAgent) || "General"); elide: Text.ElideRight; font.pixelSize: 11; color: Theme.secondary }
                                    }
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true; spacing: 7
                                    FieldLabel { text: "Skills" }
                                    Rectangle {
                                        Layout.fillWidth: true; implicitHeight: 38; radius: 7; color: "#0d101b"; border.color: root.edge
                                        MokaidLabel { anchors.fill: parent; anchors.margins: 11; text: root.controller.skillNames(root.selectedAgent).join(", ") || "No skills listed"; elide: Text.ElideRight; font.pixelSize: 11; color: Theme.secondary }
                                    }
                                }
                            }
                            MokaidLabel { Layout.fillWidth: true; text: "Category and skills follow your agent’s profile."; font.pixelSize: 10; color: Theme.muted; wrapMode: Text.Wrap }
                        }
                        ColumnLayout {
                            visible: root.wizardStep === 1
                            Layout.fillWidth: true; spacing: 15
                            RowLayout {
                                spacing: 12
                                WorkforcePortrait { agent: root.controller.faceAgent(root.selectedAgent); size: 56 }
                                ColumnLayout {
                                    Layout.fillWidth: true; spacing: 4
                                    MokaidLabel { text: root.selectedAgent.display_name || "Agent"; font.pixelSize: 16; font.weight: Font.DemiBold; Layout.fillWidth: true; elide: Text.ElideRight }
                                    MokaidLabel { text: root.controller.roleTitle(root.selectedAgent) || "AI agent"; font.pixelSize: 11; color: Theme.secondary }
                                    MokaidLabel { text: "Level " + (root.controller.publishRow.level || 1) + "  ·  " + (root.selectedAgent.missions_completed || 0) + " completed missions"; font.pixelSize: 11; color: "#c4a2f7" }
                                }
                            }
                            Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.edge }
                            FieldLabel { text: "Included with every copy" }
                            Repeater {
                                model: ["The agent’s portrait, role, skills and trained level", (root.controller.publishRow.knowledge_item_count || 0) + " linked knowledge items, including their source material"]
                                RowLayout { required property string modelData; Layout.fillWidth: true; spacing: 9; MokaidIcon { name: "tasks"; size: 15; color: "#a66bff"; Layout.alignment: Qt.AlignTop } MokaidLabel { Layout.fillWidth: true; text: modelData; wrapMode: Text.Wrap; font.pixelSize: 12; color: Theme.secondary } }
                            }
                            FieldLabel { text: "Stays in your workspace"; Layout.topMargin: 5 }
                            MokaidLabel { Layout.fillWidth: true; text: "Your original agent, conversations, tasks, Drive files and installed connectors remain yours."; wrapMode: Text.Wrap; font.pixelSize: 12; color: Theme.secondary }
                            Flow {
                                Layout.fillWidth: true; spacing: 6
                                Repeater {
                                    model: root.controller.skillNames(root.selectedAgent)
                                    Rectangle {
                                        required property string modelData
                                        implicitWidth: skillText.implicitWidth + 16; implicitHeight: 26; radius: 6; color: "#201935"; border.color: "#46305d"
                                        MokaidLabel { id: skillText; anchors.centerIn: parent; text: modelData; font.pixelSize: 10; color: "#d9c1ff" }
                                    }
                                }
                            }
                        }
                        ColumnLayout {
                            visible: root.wizardStep === 2
                            Layout.fillWidth: true; spacing: 12
                            FieldLabel { text: "Listing type" }
                            RowLayout {
                                Layout.fillWidth: true; spacing: 8
                                Pill { Layout.fillWidth: true; text: "Sell copies"; selected: root.controller.publishMode === "sale"; onClicked: root.controller.publishMode = "sale" }
                                Pill { Layout.fillWidth: true; text: "For rent"; selected: root.controller.publishMode === "rent"; onClicked: root.controller.publishMode = "rent" }
                            }
                            MokaidLabel { Layout.fillWidth: true; text: root.controller.publishMode === "sale" ? "Each buyer receives their own permanent copy." : "Renters receive a copy for the selected access period."; font.pixelSize: 11; color: Theme.secondary; wrapMode: Text.Wrap }
                            FieldLabel { visible: root.controller.publishMode === "rent"; text: "Rental period" }
                            Flow {
                                visible: root.controller.publishMode === "rent"
                                Layout.fillWidth: true; spacing: 6
                                Repeater {
                                    model: [{id:"subscription",days:0,label:"Monthly"},{id:"fixed",days:7,label:"7 days"},{id:"fixed",days:30,label:"30 days"},{id:"fixed",days:90,label:"90 days"}]
                                    Pill {
                                        required property var modelData
                                        text: modelData.label
                                        selected: root.controller.publishRentBilling === modelData.id && (modelData.id === "subscription" || root.controller.publishFixedDays === modelData.days)
                                        onClicked: { root.controller.publishRentBilling = modelData.id; if (modelData.days) root.controller.publishFixedDays = modelData.days }
                                    }
                                }
                            }
                            FieldLabel { text: "Price (USD)"; Layout.topMargin: 6 }
                            MokaidTextField {
                                objectName: "marketplacePublishPrice"
                                Layout.fillWidth: true; implicitHeight: 40
                                text: root.controller.publishPrice
                                inputMethodHints: Qt.ImhFormattedNumbersOnly
                                validator: DoubleValidator { bottom: 0; top: 999999; decimals: 2; notation: DoubleValidator.StandardNotation; locale: "en_US" }
                                onTextEdited: root.controller.publishPrice = text
                                Accessible.name: "Price in USD"
                            }
                            MokaidLabel { Layout.fillWidth: true; text: root.controller.priceValid ? "You receive " + root.controller.money(root.controller.payout.net, "usd") + " after the " + root.controller.feePercent + "% platform fee." : "Enter a price of at least USD 1.00."; color: root.controller.priceValid ? "#bdaaed" : Theme.warning; font.pixelSize: 11; wrapMode: Text.Wrap }
                        }
                        ColumnLayout {
                            visible: root.wizardStep === 3
                            Layout.fillWidth: true; spacing: 13
                            MokaidLabel { Layout.fillWidth: true; text: "Your listing will become visible to buyers as soon as it is published."; font.pixelSize: 12; color: Theme.secondary; wrapMode: Text.Wrap }
                            Repeater {
                                model: [{label:"Listing",value:root.controller.publishTitle || "—"}, {label:"Type",value:root.controller.publishMode === "rent" ? "For rent" : "For sale"}, {label:"Buyer pays",value:root.controller.money(root.controller.payout.gross,"usd")}, {label:"Platform fee (" + root.controller.feePercent + "%)",value:root.controller.money(root.controller.payout.fee,"usd")}, {label:"You receive",value:root.controller.money(root.controller.payout.net,"usd")}]
                                RowLayout { required property var modelData; Layout.fillWidth: true; MokaidLabel { text: modelData.label; color: Theme.secondary; font.pixelSize: 11 } Item { Layout.fillWidth: true } MokaidLabel { text: modelData.value; Layout.fillWidth: true; horizontalAlignment: Text.AlignRight; elide: Text.ElideRight; font.pixelSize: 12; font.weight: Font.DemiBold } }
                            }
                            Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.edge }
                            MokaidLabel { Layout.fillWidth: true; text: "You can pause the listing at any time. Copies already delivered stay with their owners."; font.pixelSize: 11; color: Theme.secondary; wrapMode: Text.Wrap }
                            ColumnLayout {
                                visible: root.connectKnown && !root.connectReady
                                Layout.fillWidth: true
                                MokaidLabel { text: "Connect Stripe before publishing."; color: Theme.warning; font.pixelSize: 12 }
                                MokaidButton { text: "Set up payouts"; implicitHeight: 34; font.pixelSize: 11; onClicked: root.controller.closeOffer("earnings") }
                            }
                        }
                    }
                }
                Section {
                    Layout.preferredWidth: Math.max(215, root.width * .32)
                    Layout.alignment: Qt.AlignTop
                    implicitHeight: previewColumn.implicitHeight + 28
                    ColumnLayout {
                        id: previewColumn
                        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 14
                        spacing: 12
                        FieldLabel { text: "Preview" }
                        Rectangle {
                            Layout.fillWidth: true; Layout.preferredHeight: 140; radius: 8; border.color: "#67418f"
                            gradient: Gradient { GradientStop { position: 0; color: "#392052" } GradientStop { position: 1; color: "#211531" } }
                            WorkforcePortrait { anchors.centerIn: parent; agent: root.controller.faceAgent(root.selectedAgent); size: 95 }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: 4
                            MokaidLabel { text: root.controller.publishTitle || root.selectedAgent.display_name || "Your agent name"; Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: 14; font.weight: Font.DemiBold }
                            MokaidLabel { text: root.controller.roleTitle(root.selectedAgent) || "AI agent"; Layout.fillWidth: true; elide: Text.ElideRight; color: Theme.secondary; font.pixelSize: 11 }
                            MokaidLabel { text: root.controller.publishDescription || "Add a description to tell buyers what your agent can do."; Layout.fillWidth: true; wrapMode: Text.Wrap; maximumLineCount: 4; elide: Text.ElideRight; color: Theme.muted; font.pixelSize: 11; Layout.topMargin: 4 }
                        }
                        MokaidLabel { text: "Level " + (root.controller.publishRow.level || 1) + "  ·  " + (root.controller.publishRow.knowledge_item_count || 0) + " knowledge items"; color: "#ba9de4"; font.pixelSize: 10; Layout.fillWidth: true; wrapMode: Text.Wrap }
                        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.edge }
                        MokaidLabel { text: root.controller.priceValid ? root.controller.money(root.controller.payout.gross,"usd") + (root.controller.publishMode === "rent" ? root.controller.publishRentBilling === "subscription" ? " / month" : " / " + root.controller.publishFixedDays + " days" : "") : "Set a price"; font.pixelSize: 14; font.weight: Font.DemiBold; Layout.fillWidth: true; wrapMode: Text.Wrap }
                        MokaidLabel { text: root.controller.publishMode === "sale" ? "One-time purchase" : root.controller.publishRentBilling === "subscription" ? "Monthly subscription" : "Fixed-term rental"; color: Theme.muted; font.pixelSize: 10 }
                    }
                }
            }
            RowLayout {
                Layout.fillWidth: true
                MokaidLabel { Layout.fillWidth: true; text: "Step " + (root.wizardStep + 1) + " of 4"; font.pixelSize: 11; color: Theme.muted }
                MokaidButton { text: root.wizardStep ? "Back" : "Cancel"; implicitHeight: 36; font.pixelSize: 11; enabled: !features.busy; onClicked: { if (root.wizardStep) root.wizardStep--; else root.controller.closeOffer("mine") } }
                PrimaryButton {
                    objectName: "marketplacePublishNext"
                    text: root.wizardStep === 3 ? root.controller.publishPending ? "Publishing…" : "Publish listing" : "Next →"
                    enabled: !features.busy && (root.wizardStep === 3 ? root.canPublish : root.stepValid)
                    onClicked: { if (root.wizardStep < 3) { root.wizardStep++; wizardScroll.contentY = 0 } else root.controller.confirmPublish() }
                }
            }
        }
    }
}
