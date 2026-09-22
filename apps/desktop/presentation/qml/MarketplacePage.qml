pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root
    objectName: "marketplacePage"
    signal actionRequested(var action)

    property string tab: "discover"
    property string modeFilter: "all"
    property string publishAgentId: ""
    property string publishMode: "sale"
    property string publishRentBilling: "subscription"
    property int publishFixedDays: 30
    property string publishPrice: "49"
    property string connectCountry: "US"
    property var mineRows: []
    property var earningsData: ({})
    property string selectedListingId: ""

    readonly property var listings: {
        const rows = features.allRecords || []
        return rows.filter(function(row) {
            if (root.modeFilter === "all") return true
            return row.mode === root.modeFilter
        })
    }
    readonly property var selectedListing: {
        return listings.find(function(row) { return row.id === root.selectedListingId }) || ({})
    }
    readonly property color panelBorder: "#302940"
    readonly property color panelSurface: "#11121e"
    readonly property color supportingText: "#adb6d4"
    readonly property int minLevel: 10

    function money(cents, currency) {
        const amount = Number(cents || 0) / 100
        const code = String(currency || "usd").toUpperCase()
        return code + " " + amount.toFixed(2)
    }
    function priceLabel(row) {
        const base = money(row.price_cents, row.currency)
        if (row.mode === "sale") return base
        if (row.rent_billing === "subscription") return base + " / month"
        return base + " · " + (row.fixed_days || 30) + " days"
    }
    function agentName(row) {
        if (row.title) return row.title
        if (row.agent && row.agent.display_name) return row.agent.display_name
        if (row.agent && row.agent.display_name === undefined && row.agent.id) return "Agent"
        return "Listed agent"
    }
    function mineAgent(row) {
        return (row && row.agent) ? row.agent : ({})
    }
    function refreshTab() {
        if (root.tab === "discover") features.refresh()
        else if (root.tab === "mine") features.submit("mine", {})
        else if (root.tab === "earnings") features.submit("earnings", {})
    }
    function openCheckout(listingId) {
        features.submit("checkout", { listing_id: listingId, _confirmed: true })
    }
    function publishListing() {
        const priceCents = Math.round(Number(root.publishPrice) * 100)
        const values = {
            agent_id: root.publishAgentId,
            mode: root.publishMode,
            price_cents: priceCents,
            _confirmed: true
        }
        if (root.publishMode === "rent") {
            values.rent_billing = root.publishRentBilling
            if (root.publishRentBilling === "fixed") values.fixed_days = String(root.publishFixedDays)
        }
        features.submit("publish", values)
    }
    function toggleListing(listing) {
        if (!listing || !listing.id) return
        const action = listing.status === "paused" ? "resume" : "pause"
        features.submit(action, { _id: listing.id, _confirmed: true })
    }
    function startConnect() {
        features.submit("connect-onboard", { country: root.connectCountry, _confirmed: true })
    }

    Connections {
        target: features
        function onChanged() {
            if (features.currentPage !== "marketplace") return
            const details = features.details || ({})
            if (root.tab === "mine" && details.items) {
                root.mineRows = details.items
                if (details.meta) root.earningsData = Object.assign({}, root.earningsData, { meta: details.meta })
            } else if (root.tab === "mine" && Array.isArray(details) === false && details.connect !== undefined) {
                // earnings shape accidentally — ignore
            } else if (root.tab === "mine" && details.agent) {
                // single row unlikely
            }
            // GET mine returns data as array → details.items
            // GET earnings returns object with connect, listings, etc.
            if (root.tab === "earnings" && (details.connect !== undefined || details.listings !== undefined || details.gross_cents !== undefined)) {
                root.earningsData = details
            }
            if (root.tab === "mine" && details.meta) {
                const items = details.items || []
                if (items.length || details.meta.connect !== undefined) root.mineRows = items
            }
        }
    }

    onTabChanged: refreshTab()
    Component.onCompleted: refreshTab()

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 4
        spacing: 16

        RowLayout {
            Layout.fillWidth: true
            spacing: 16
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 4
                MokaidLabel { text: "Marketplace"; font.pixelSize: 26; font.weight: Font.DemiBold }
                MokaidLabel {
                    Layout.fillWidth: true
                    text: "Sell copies or rent level-10 agents with their knowledge. Stripe Connect pays the creator; Mokaid takes 15%."
                    color: root.supportingText; font.pixelSize: 13; wrapMode: Text.Wrap
                }
            }
            MokaidButton { iconName: "refresh"; quiet: true; enabled: !features.busy; Accessible.name: "Refresh marketplace"; onClicked: root.refreshTab() }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Repeater {
                model: [
                    { id: "discover", label: "Discover" },
                    { id: "mine", label: "My agents" },
                    { id: "earnings", label: "Earnings" }
                ]
                AbstractButton {
                    id: tabButton
                    required property var modelData
                    Layout.preferredHeight: 40
                    leftPadding: 16; rightPadding: 16
                    Accessible.name: modelData.label
                    Accessible.role: Accessible.PageTab
                    onClicked: root.tab = modelData.id
                    background: Rectangle {
                        radius: 10
                        color: root.tab === tabButton.modelData.id ? "#392269" : (tabButton.hovered ? "#222036" : "transparent")
                        border.color: root.tab === tabButton.modelData.id ? "#8b5ded" : "transparent"
                    }
                    contentItem: MokaidLabel {
                        text: tabButton.modelData.label
                        font.pixelSize: 13
                        font.weight: root.tab === tabButton.modelData.id ? Font.DemiBold : Font.Normal
                        color: root.tab === tabButton.modelData.id ? Theme.text : Theme.secondary
                        horizontalAlignment: Text.AlignHCenter
                    }
                }
            }
            Item { Layout.fillWidth: true }
        }

        // Discover
        RowLayout {
            visible: root.tab === "discover"
            Layout.fillWidth: true; Layout.fillHeight: true
            spacing: 16

            ColumnLayout {
                Layout.fillWidth: true; Layout.fillHeight: true
                spacing: 12

                RowLayout {
                    spacing: 8
                    Repeater {
                        model: [
                            { id: "all", label: "All" },
                            { id: "sale", label: "For sale" },
                            { id: "rent", label: "For rent" }
                        ]
                        AbstractButton {
                            id: filterBtn
                            required property var modelData
                            Layout.preferredHeight: 34
                            leftPadding: 12; rightPadding: 12
                            onClicked: root.modeFilter = modelData.id
                            background: Rectangle {
                                radius: 8
                                color: root.modeFilter === filterBtn.modelData.id ? "#2a2444" : "transparent"
                                border.color: root.modeFilter === filterBtn.modelData.id ? "#6b5b95" : root.panelBorder
                            }
                            contentItem: MokaidLabel {
                                text: filterBtn.modelData.label; font.pixelSize: 12
                                color: root.modeFilter === filterBtn.modelData.id ? Theme.text : Theme.secondary
                            }
                        }
                    }
                    Item { Layout.fillWidth: true }
                    MokaidLabel {
                        visible: features.busy
                        text: "Loading…"
                        color: Theme.secondary; font.pixelSize: 12
                    }
                }

                GridView {
                    id: listingGrid
                    Layout.fillWidth: true; Layout.fillHeight: true
                    clip: true
                    cellWidth: Math.max(260, (width - 12) / Math.max(1, Math.floor(width / 280)))
                    cellHeight: 168
                    model: root.listings
                    delegate: AbstractButton {
                        id: card
                        required property var modelData
                        width: listingGrid.cellWidth - 12
                        height: listingGrid.cellHeight - 12
                        onClicked: root.selectedListingId = modelData.id
                        background: Rectangle {
                            radius: 14
                            color: root.selectedListingId === card.modelData.id ? "#1a1730" : root.panelSurface
                            border.color: root.selectedListingId === card.modelData.id ? "#8b5ded" : root.panelBorder
                            gradient: Gradient {
                                GradientStop { position: 0; color: root.selectedListingId === card.modelData.id ? "#241c3c" : "#141528" }
                                GradientStop { position: 1; color: root.panelSurface }
                            }
                        }
                        contentItem: ColumnLayout {
                            anchors.fill: parent; anchors.margins: 14; spacing: 8
                            RowLayout {
                                Layout.fillWidth: true
                                Rectangle {
                                    Layout.preferredWidth: 40; Layout.preferredHeight: 40; radius: 12
                                    color: "#2a2448"; border.color: "#5b4d82"
                                    MokaidLabel {
                                        anchors.centerIn: parent
                                        text: root.agentName(card.modelData).slice(0, 1).toUpperCase()
                                        font.pixelSize: 16; font.weight: Font.DemiBold; color: "#e4d9ff"
                                    }
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true; spacing: 2
                                    MokaidLabel {
                                        Layout.fillWidth: true
                                        text: root.agentName(card.modelData)
                                        font.pixelSize: 14; font.weight: Font.DemiBold; elide: Text.ElideRight
                                    }
                                    MokaidLabel {
                                        text: (card.modelData.agent && card.modelData.agent.role_title) || "AI employee"
                                        color: root.supportingText; font.pixelSize: 11; elide: Text.ElideRight
                                        Layout.fillWidth: true
                                    }
                                }
                                Rectangle {
                                    radius: 8; color: card.modelData.mode === "sale" ? "#1d3a2e" : "#2a2448"
                                    border.color: card.modelData.mode === "sale" ? "#3d8f6a" : "#6b5b95"
                                    implicitHeight: 24; implicitWidth: badgeLabel.implicitWidth + 14
                                    MokaidLabel {
                                        id: badgeLabel; anchors.centerIn: parent
                                        text: card.modelData.mode === "sale" ? "Sale" : "Rent"
                                        font.pixelSize: 10; font.weight: Font.DemiBold
                                    }
                                }
                            }
                            Item { Layout.fillHeight: true }
                            RowLayout {
                                Layout.fillWidth: true
                                MokaidLabel {
                                    text: "Lvl " + (card.modelData.agent_level || card.modelData.agent && card.modelData.agent.level || "—")
                                    color: root.supportingText; font.pixelSize: 11
                                }
                                MokaidLabel {
                                    text: (card.modelData.knowledge_item_count || 0) + " knowledge"
                                    color: root.supportingText; font.pixelSize: 11
                                }
                                Item { Layout.fillWidth: true }
                                MokaidLabel {
                                    text: root.priceLabel(card.modelData)
                                    font.pixelSize: 13; font.weight: Font.DemiBold; color: "#dbc3ff"
                                }
                            }
                        }
                    }
                }

                MokaidLabel {
                    visible: !features.busy && root.listings.length === 0
                    Layout.fillWidth: true
                    text: "No agents are listed yet. Reach level 10 and publish from My agents."
                    color: Theme.secondary; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap
                }
            }

            Rectangle {
                visible: !!root.selectedListing.id
                Layout.preferredWidth: Math.min(340, parent.width * 0.38)
                Layout.fillHeight: true
                radius: 16; color: root.panelSurface; border.color: root.panelBorder
                ColumnLayout {
                    anchors.fill: parent; anchors.margins: 18; spacing: 12
                    MokaidLabel {
                        Layout.fillWidth: true
                        text: root.agentName(root.selectedListing)
                        font.pixelSize: 20; font.weight: Font.DemiBold; wrapMode: Text.Wrap
                    }
                    MokaidLabel {
                        Layout.fillWidth: true
                        text: root.priceLabel(root.selectedListing)
                        color: "#dbc3ff"; font.pixelSize: 16; font.weight: Font.DemiBold
                    }
                    MokaidLabel {
                        Layout.fillWidth: true
                        text: root.selectedListing.mode === "sale"
                              ? "You receive a full copy of this agent and its linked knowledge. The seller keeps the original."
                              : (root.selectedListing.rent_billing === "subscription"
                                 ? "Monthly rental. Cancel anytime; access ends after the paid period."
                                 : "Fixed " + (root.selectedListing.fixed_days || 30) + "-day rental. Access ends when the term expires.")
                        color: root.supportingText; font.pixelSize: 12; wrapMode: Text.Wrap
                    }
                    MokaidLabel {
                        Layout.fillWidth: true
                        text: (root.selectedListing.knowledge_item_count || 0) + " knowledge items travel with the agent. Conversations, tasks, Drive files and connectors stay with the seller."
                        color: root.supportingText; font.pixelSize: 12; wrapMode: Text.Wrap
                    }
                    Item { Layout.fillHeight: true }
                    MokaidButton {
                        Layout.fillWidth: true
                        text: root.selectedListing.mode === "sale" ? "Buy copy" : "Rent agent"
                        highlighted: true
                        enabled: !features.busy && !!root.selectedListing.id
                        onClicked: root.openCheckout(root.selectedListing.id)
                    }
                }
            }
        }

        // My agents
        Flickable {
            visible: root.tab === "mine"
            Layout.fillWidth: true; Layout.fillHeight: true
            contentWidth: width
            contentHeight: mineColumn.implicitHeight
            clip: true
            ColumnLayout {
                id: mineColumn
                width: parent.width
                spacing: 12

                Rectangle {
                    Layout.fillWidth: true
                    radius: 14; color: "#1a1730"; border.color: "#5b4d82"
                    implicitHeight: lockHint.implicitHeight + 28
                    MokaidLabel {
                        id: lockHint
                        anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                        anchors.margins: 14
                        text: "Agents cannot go live on the marketplace until they reach level " + root.minLevel + ". Train them with missions until the lock opens."
                        wrapMode: Text.Wrap; font.pixelSize: 13; color: "#e2d4ff"
                    }
                }

                Repeater {
                    model: root.mineRows
                    delegate: Rectangle {
                        id: mineCard
                        required property var modelData
                        Layout.fillWidth: true
                        radius: 14; color: root.panelSurface; border.color: root.panelBorder
                        implicitHeight: mineInner.implicitHeight + 28
                        readonly property var agent: root.mineAgent(modelData)
                        readonly property bool eligible: !!modelData.eligible
                        readonly property bool locked: !eligible

                        ColumnLayout {
                            id: mineInner
                            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                            anchors.margins: 14
                            spacing: 10

                            RowLayout {
                                Layout.fillWidth: true
                                ColumnLayout {
                                    Layout.fillWidth: true; spacing: 2
                                    MokaidLabel {
                                        text: mineCard.agent.display_name || "Agent"
                                        font.pixelSize: 15; font.weight: Font.DemiBold
                                    }
                                    MokaidLabel {
                                        text: "Level " + (modelData.level || mineCard.agent.level || 1) + " / " + root.minLevel
                                              + " · " + (modelData.knowledge_item_count || 0) + " knowledge items"
                                        color: root.supportingText; font.pixelSize: 12
                                    }
                                }
                                Rectangle {
                                    visible: mineCard.locked
                                    radius: 8; color: "#2a1c24"; border.color: "#8a4a5c"
                                    implicitHeight: 26; implicitWidth: lockLabel.implicitWidth + 16
                                    MokaidLabel {
                                        id: lockLabel; anchors.centerIn: parent
                                        text: "Locked · " + (modelData.levels_remaining || 0) + " levels left"
                                        font.pixelSize: 11; color: "#ffb4c4"
                                    }
                                }
                                Rectangle {
                                    visible: !mineCard.locked && modelData.listing
                                    radius: 8; color: "#1d3a2e"; border.color: "#3d8f6a"
                                    implicitHeight: 26; implicitWidth: liveLabel.implicitWidth + 16
                                    MokaidLabel {
                                        id: liveLabel; anchors.centerIn: parent
                                        text: (modelData.listing.status || "active") === "paused" ? "Paused" : "Live"
                                        font.pixelSize: 11
                                    }
                                }
                            }

                            // Progress bar toward level 10
                            Rectangle {
                                Layout.fillWidth: true; Layout.preferredHeight: 6; radius: 3; color: "#1c1d2c"
                                Rectangle {
                                    width: parent.width * Math.min(1, Number(modelData.level || 0) / root.minLevel)
                                    height: parent.height; radius: 3; color: mineCard.locked ? "#8a4a5c" : "#8b5ded"
                                }
                            }

                            RowLayout {
                                visible: mineCard.eligible && !modelData.listing
                                Layout.fillWidth: true
                                spacing: 8
                                MokaidButton {
                                    text: "Sell copies"
                                    highlighted: root.publishAgentId === mineCard.agent.id && root.publishMode === "sale"
                                    onClicked: { root.publishAgentId = mineCard.agent.id; root.publishMode = "sale" }
                                }
                                MokaidButton {
                                    text: "Rent out"
                                    highlighted: root.publishAgentId === mineCard.agent.id && root.publishMode === "rent"
                                    onClicked: { root.publishAgentId = mineCard.agent.id; root.publishMode = "rent" }
                                }
                            }

                            ColumnLayout {
                                visible: mineCard.eligible && !modelData.listing && root.publishAgentId === mineCard.agent.id
                                Layout.fillWidth: true
                                spacing: 8
                                RowLayout {
                                    visible: root.publishMode === "rent"
                                    MokaidButton {
                                        text: "Monthly"
                                        highlighted: root.publishRentBilling === "subscription"
                                        onClicked: root.publishRentBilling = "subscription"
                                    }
                                    MokaidButton {
                                        text: "7 days"
                                        highlighted: root.publishRentBilling === "fixed" && root.publishFixedDays === 7
                                        onClicked: { root.publishRentBilling = "fixed"; root.publishFixedDays = 7 }
                                    }
                                    MokaidButton {
                                        text: "30 days"
                                        highlighted: root.publishRentBilling === "fixed" && root.publishFixedDays === 30
                                        onClicked: { root.publishRentBilling = "fixed"; root.publishFixedDays = 30 }
                                    }
                                    MokaidButton {
                                        text: "90 days"
                                        highlighted: root.publishRentBilling === "fixed" && root.publishFixedDays === 90
                                        onClicked: { root.publishRentBilling = "fixed"; root.publishFixedDays = 90 }
                                    }
                                }
                                RowLayout {
                                    MokaidLabel { text: "Price (USD)"; color: Theme.secondary; font.pixelSize: 12 }
                                    MokaidTextField {
                                        Layout.preferredWidth: 120
                                        text: root.publishPrice
                                        onTextChanged: root.publishPrice = text
                                    }
                                    Item { Layout.fillWidth: true }
                                    MokaidButton {
                                        text: "Publish"
                                        highlighted: true
                                        enabled: !features.busy
                                        onClicked: root.publishListing()
                                    }
                                }
                                MokaidLabel {
                                    Layout.fillWidth: true
                                    text: "Includes agent-scoped knowledge only. Conversations, tasks, Drive files and MCP installs stay private."
                                    color: root.supportingText; font.pixelSize: 11; wrapMode: Text.Wrap
                                }
                            }

                            RowLayout {
                                visible: !!modelData.listing
                                MokaidButton {
                                    text: modelData.listing.status === "paused" ? "Resume" : "Pause"
                                    onClicked: root.toggleListing(modelData.listing)
                                }
                                MokaidLabel {
                                    text: root.priceLabel(modelData.listing)
                                    color: "#dbc3ff"; font.pixelSize: 13
                                }
                            }

                            MokaidLabel {
                                visible: mineCard.locked
                                Layout.fillWidth: true
                                text: "It is impossible to put this agent online until it reaches level " + root.minLevel + "."
                                color: "#ffb4c4"; font.pixelSize: 12; wrapMode: Text.Wrap
                            }
                        }
                    }
                }

                MokaidLabel {
                    visible: !features.busy && root.mineRows.length === 0
                    Layout.fillWidth: true
                    text: features.error || "Load your agents to publish, or create an AI agent first."
                    color: Theme.secondary; wrapMode: Text.Wrap
                }
            }
        }

        // Earnings
        Flickable {
            visible: root.tab === "earnings"
            Layout.fillWidth: true; Layout.fillHeight: true
            contentWidth: width
            contentHeight: earnColumn.implicitHeight
            clip: true
            ColumnLayout {
                id: earnColumn
                width: parent.width
                spacing: 14

                Rectangle {
                    Layout.fillWidth: true
                    radius: 16; color: root.panelSurface; border.color: root.panelBorder
                    implicitHeight: connectCol.implicitHeight + 32
                    ColumnLayout {
                        id: connectCol
                        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                        anchors.margins: 16
                        spacing: 10
                        MokaidLabel { text: "Payouts"; font.pixelSize: 18; font.weight: Font.DemiBold }
                        MokaidLabel {
                            Layout.fillWidth: true
                            text: root.earningsData.connect_ready
                                  ? "Stripe Connect is ready. You earn " + (100 - (root.earningsData.fee_percent || 15)) + "% of each sale and rental."
                                  : "Set up Stripe Connect before publishing. Mokaid keeps " + (root.earningsData.fee_percent || 15) + "% on every payment."
                            color: root.supportingText; wrapMode: Text.Wrap; font.pixelSize: 13
                        }
                        RowLayout {
                            visible: !root.earningsData.connect_ready
                            MokaidTextField {
                                Layout.preferredWidth: 80
                                text: root.connectCountry
                                onTextChanged: root.connectCountry = text.toUpperCase()
                                placeholderText: "US"
                            }
                            MokaidButton {
                                text: "Set up payouts"
                                highlighted: true
                                enabled: !features.busy && root.connectCountry.length === 2
                                onClicked: root.startConnect()
                            }
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12
                    Repeater {
                        model: [
                            { label: "Gross", value: root.money(root.earningsData.gross_cents, "usd") },
                            { label: "Platform fee", value: root.money(root.earningsData.fee_cents, "usd") },
                            { label: "Your net", value: root.money(root.earningsData.net_cents, "usd") }
                        ]
                        Rectangle {
                            required property var modelData
                            Layout.fillWidth: true
                            radius: 14; color: root.panelSurface; border.color: root.panelBorder
                            implicitHeight: 88
                            ColumnLayout {
                                anchors.fill: parent; anchors.margins: 16; spacing: 6
                                MokaidLabel { text: modelData.label; color: Theme.secondary; font.pixelSize: 11 }
                                MokaidLabel { text: modelData.value; font.pixelSize: 20; font.weight: Font.DemiBold }
                            }
                        }
                    }
                }

                MokaidLabel { text: "Active listings"; font.pixelSize: 15; font.weight: Font.DemiBold }
                Repeater {
                    model: root.earningsData.listings || []
                    delegate: Rectangle {
                        required property var modelData
                        Layout.fillWidth: true
                        radius: 12; color: root.panelSurface; border.color: root.panelBorder
                        implicitHeight: 56
                        RowLayout {
                            anchors.fill: parent; anchors.margins: 14
                            MokaidLabel {
                                Layout.fillWidth: true
                                text: (modelData.title || (modelData.agent && modelData.agent.display_name) || "Listing")
                                      + " · " + modelData.status
                                elide: Text.ElideRight
                            }
                            MokaidLabel { text: root.priceLabel(modelData); color: "#dbc3ff" }
                        }
                    }
                }
            }
        }
    }
}
