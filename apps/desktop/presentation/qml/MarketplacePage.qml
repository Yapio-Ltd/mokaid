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
    property string screen: "browse"
    property bool publishPending: false
    property bool publishSawBusy: false
    property string queuedOfferAgent: ""
    property string queuedOfferMode: ""
    property bool offerAwaitingRows: false
    property bool sawOfferBusy: false
    property bool mineRequested: false

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
    readonly property var sortedMineRows: {
        const rows = (root.mineRows || []).slice()
        rows.sort(function(a, b) {
            function rank(row) {
                if (row && row.listing) return 0
                if (row && row.eligible) return 1
                return 2
            }
            const order = rank(a) - rank(b)
            if (order !== 0) return order
            return Number((b && b.level) || 0) - Number((a && a.level) || 0)
        })
        return rows
    }
    readonly property var mineSummary: {
        const rows = root.mineRows || []
        let ready = 0
        let training = 0
        let live = 0
        for (let i = 0; i < rows.length; ++i) {
            const row = rows[i]
            if (row.listing) live += 1
            else if (row.eligible) ready += 1
            else training += 1
        }
        return { ready: ready, training: training, live: live, total: rows.length }
    }
    readonly property string mineHint: {
        const summary = root.mineSummary
        if (!summary.total)
            return "Create an AI agent, then train them with missions. Level " + root.minLevel + " opens the marketplace."
        if (summary.ready > 0)
            return summary.ready + (summary.ready === 1 ? " agent is ready to list." : " agents are ready to list.") + " Open Sell copies or Rent out to review the terms, then publish."
        if (summary.live > 0 && summary.training === 0)
            return "Your listings are live. Pause one anytime if you want to stop new buyers."
        return "Level " + root.minLevel + " opens the marketplace. Missions move the bar — the faces below show who is closest."
    }
    readonly property var publishRow: {
        const id = root.publishAgentId
        const rows = root.mineRows || []
        for (let i = 0; i < rows.length; ++i) {
            const row = rows[i]
            if (row && row.agent && row.agent.id === id) return row
        }
        return ({})
    }
    readonly property var publishAgent: root.mineAgent(root.publishRow)
    readonly property int feePercent: {
        const meta = root.earningsData && root.earningsData.meta
        const value = Number((root.earningsData && root.earningsData.fee_percent) || (meta && meta.fee_percent) || 15)
        return isFinite(value) ? value : 15
    }
    readonly property bool priceValid: {
        const amount = Number(root.publishPrice)
        return isFinite(amount) && Math.round(amount * 100) >= 100
    }
    readonly property var payout: {
        if (!root.priceValid) return { gross: 0, fee: 0, net: 0 }
        const gross = Math.round(Number(root.publishPrice) * 100)
        const fee = Math.max(Math.floor(gross * root.feePercent / 100), 1)
        return { gross: gross, fee: fee, net: Math.max(gross - fee, 0) }
    }
    readonly property string offerTitle: root.publishMode === "rent" ? "Rent out" : "Sell copies"
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
        if (!row) return ""
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
    function faceAgent(agent) {
        const source = agent || ({})
        return {
            kind: source.kind || "ai",
            display_name: source.display_name || source.name || "",
            avatar_cdn_path: source.avatar_cdn_path || "",
            avatar_asset_id: source.avatar_asset_id || ""
        }
    }
    function roleTitle(agent) {
        if (!agent) return ""
        return agent.role_title || agent.department || ""
    }
    function levelOf(row) {
        return Number((row && row.level) || (row && row.agent && row.agent.level) || 1)
    }
    function levelRatio(row) {
        if (!root.minLevel) return 0
        return Math.max(0, Math.min(1, root.levelOf(row) / root.minLevel))
    }
    function listingStatus(listing) {
        return (listing && listing.status) || "active"
    }
    function titleCase(value) {
        const text = String(value || "").trim()
        if (!text) return ""
        return text.charAt(0).toUpperCase() + text.slice(1)
    }
    function skillNames(agent) {
        return ((agent && agent.skills) || []).map(function(skill) {
            return typeof skill === "string" ? skill : String((skill && (skill.name || skill.label || skill.key)) || "")
        }).filter(function(skill) { return skill.length > 0 })
    }
    function openOffer(agentId, mode) {
        if (!agentId) return
        root.publishAgentId = agentId
        root.publishMode = mode
        root.publishPending = false
        root.publishSawBusy = false
        root.screen = "publish"
    }
    function closeOffer(nextTab) {
        root.publishPending = false
        root.publishSawBusy = false
        root.screen = "browse"
        if (nextTab) root.tab = nextTab
    }
    function confirmPublish() {
        if (!root.priceValid || features.busy) return
        root.publishPending = true
        root.publishSawBusy = false
        root.publishListing()
    }
    function takeOffer() {
        const agentId = features.pendingOfferAgentId || ""
        const mode = features.pendingOfferMode || ""
        if (!agentId || (mode !== "rent" && mode !== "sale")) return
        root.queuedOfferAgent = agentId
        root.queuedOfferMode = mode
        root.offerAwaitingRows = true
        root.mineRequested = false
        root.sawOfferBusy = false
        features.consumeMarketplaceOffer()
        root.ensureMineRequest()
    }
    function ensureMineRequest() {
        if (!root.offerAwaitingRows || features.busy || root.mineRequested) return
        root.mineRequested = true
        root.sawOfferBusy = false
        if (root.tab !== "mine") root.tab = "mine"
        else features.submit("mine", {})
    }
    function finishQueuedOffer() {
        const id = root.queuedOfferAgent
        const mode = root.queuedOfferMode
        root.queuedOfferAgent = ""
        root.queuedOfferMode = ""
        root.offerAwaitingRows = false
        root.sawOfferBusy = false
        if (!id || features.error) return
        let match = null
        const rows = root.mineRows || []
        for (let i = 0; i < rows.length; ++i) {
            const row = rows[i]
            if (row && row.agent && row.agent.id === id) match = row
        }
        if (match && match.eligible && !match.listing) root.openOffer(id, mode)
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
            if (root.publishPending) {
                if (features.busy) root.publishSawBusy = true
                else if (root.publishSawBusy || features.error) {
                    const failed = !!features.error
                    root.publishPending = false
                    root.publishSawBusy = false
                    if (!failed) {
                        root.screen = "browse"
                        root.tab = "mine"
                        features.submit("mine", {})
                    }
                }
            }
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
            if (root.offerAwaitingRows && !root.mineRequested && !features.busy) root.ensureMineRequest()
            if (root.offerAwaitingRows && features.busy) root.sawOfferBusy = true
            if (root.offerAwaitingRows && root.mineRequested && root.sawOfferBusy && !features.busy && root.tab === "mine")
                root.finishQueuedOffer()
        }
    }

    onTabChanged: refreshTab()
    Component.onCompleted: {
        root.takeOffer()
        if (!root.offerAwaitingRows) root.refreshTab()
    }

    component StatChip: Rectangle {
        id: chip
        property string value: "0"
        property string label: ""
        property color accent: "#dbc3ff"
        Layout.fillWidth: true
        Layout.maximumWidth: 190
        radius: 12
        color: "#141522"
        border.color: "#2c2840"
        implicitHeight: 58
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 10
            spacing: 1
            MokaidLabel { text: chip.value; font.pixelSize: 16; font.weight: Font.DemiBold; color: chip.accent; Layout.fillWidth: true; elide: Text.ElideRight }
            MokaidLabel { text: chip.label; font.pixelSize: 11; color: "#9aa6c8"; Layout.fillWidth: true; elide: Text.ElideRight }
        }
    }

    component OfferChoice: AbstractButton {
        id: choice
        property string title: ""
        property string caption: ""
        property bool selected: false
        Layout.fillWidth: true
        implicitHeight: 62
        hoverEnabled: true
        background: Rectangle {
            radius: 12
            color: choice.selected ? "#241b3c" : (choice.hovered ? "#1a1830" : "#121320")
            border.color: choice.visualFocus ? Theme.focusBorder : choice.selected ? "#8b5ded" : "#2e2942"
            border.width: choice.selected ? 1.5 : 1
        }
        contentItem: ColumnLayout {
            anchors.fill: parent
            anchors.leftMargin: 12
            anchors.rightMargin: 12
            spacing: 2
            MokaidLabel {
                text: choice.title
                font.pixelSize: 13
                font.weight: Font.DemiBold
                color: choice.selected ? "#f4ecff" : Theme.text
            }
            MokaidLabel {
                text: choice.caption
                font.pixelSize: 11
                color: "#9aa6c8"
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 4
        spacing: 16

        RowLayout {
            visible: root.screen === "browse"
            Layout.fillWidth: true
            spacing: 16
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 4
                MokaidLabel { text: "Marketplace"; font.pixelSize: 26; font.weight: Font.DemiBold }
                MokaidLabel {
                    Layout.fillWidth: true
                    text: "Sell a copy or rent a trained agent, knowledge included. You keep 85% — Stripe Connect pays you directly."
                    color: root.supportingText; font.pixelSize: 13; wrapMode: Text.Wrap
                }
            }
            MokaidButton { iconName: "refresh"; quiet: true; enabled: !features.busy; Accessible.name: "Refresh marketplace"; onClicked: root.refreshTab() }
        }

        Rectangle {
            visible: root.screen === "browse"
            implicitWidth: tabRow.implicitWidth + 8
            implicitHeight: 42
            radius: 13
            color: "#10121b"
            border.color: root.panelBorder
            Layout.alignment: Qt.AlignLeft
            Row {
                id: tabRow
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: 4
                spacing: 2
                Repeater {
                    model: [
                        { id: "discover", label: "Discover" },
                        { id: "mine", label: "My agents" },
                        { id: "earnings", label: "Earnings" }
                    ]
                    AbstractButton {
                        id: tabButton
                        required property var modelData
                        implicitWidth: tabLabel.implicitWidth + 32
                        implicitHeight: 34
                        Accessible.name: modelData.label
                        Accessible.role: Accessible.PageTab
                        hoverEnabled: true
                        onClicked: root.tab = modelData.id
                        background: Rectangle {
                            radius: 10
                            color: root.tab === tabButton.modelData.id ? "#392269" : (tabButton.hovered ? "#1c1a2e" : "transparent")
                            border.color: root.tab === tabButton.modelData.id ? "#8b5ded" : "transparent"
                        }
                        contentItem: MokaidLabel {
                            id: tabLabel
                            text: tabButton.modelData.label
                            font.pixelSize: 13
                            font.weight: root.tab === tabButton.modelData.id ? Font.DemiBold : Font.Normal
                            color: root.tab === tabButton.modelData.id ? Theme.text : Theme.secondary
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }
            }
        }

        // Discover
        RowLayout {
            visible: root.screen === "browse" && root.tab === "discover"
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
                            implicitHeight: 34
                            implicitWidth: filterLabel.implicitWidth + 24
                            hoverEnabled: true
                            onClicked: root.modeFilter = modelData.id
                            background: Rectangle {
                                radius: 10
                                color: root.modeFilter === filterBtn.modelData.id ? "#2a2444" : (filterBtn.hovered ? "#1a1830" : "transparent")
                                border.color: root.modeFilter === filterBtn.modelData.id ? "#6b5b95" : root.panelBorder
                            }
                            contentItem: MokaidLabel {
                                id: filterLabel
                                text: filterBtn.modelData.label
                                font.pixelSize: 12
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
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
                    visible: features.busy || root.listings.length > 0
                    Layout.fillWidth: true; Layout.fillHeight: true
                    clip: true
                    cellWidth: Math.max(280, (width - 12) / Math.max(1, Math.floor(width / 300)))
                    cellHeight: 196
                    model: root.listings
                    delegate: AbstractButton {
                        id: card
                        required property var modelData
                        width: listingGrid.cellWidth - 12
                        height: listingGrid.cellHeight - 12
                        hoverEnabled: true
                        onClicked: root.selectedListingId = modelData.id
                        Accessible.name: root.agentName(modelData) + ", " + root.priceLabel(modelData)
                        background: Rectangle {
                            radius: 16
                            color: root.selectedListingId === card.modelData.id ? "#1a1730" : (card.hovered ? "#161528" : root.panelSurface)
                            border.color: card.visualFocus ? Theme.focusBorder : root.selectedListingId === card.modelData.id ? "#8b5ded" : root.panelBorder
                            border.width: root.selectedListingId === card.modelData.id ? 1.5 : 1
                        }
                        contentItem: ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 14
                            spacing: 10
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 12
                                WorkforcePortrait {
                                    agent: root.faceAgent(card.modelData.agent)
                                    size: 56
                                    Layout.alignment: Qt.AlignVCenter
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 3
                                    MokaidLabel {
                                        Layout.fillWidth: true
                                        text: root.agentName(card.modelData)
                                        font.pixelSize: 15
                                        font.weight: Font.DemiBold
                                        elide: Text.ElideRight
                                    }
                                    MokaidLabel {
                                        text: root.roleTitle(card.modelData.agent) || "AI employee"
                                        color: root.supportingText
                                        font.pixelSize: 12
                                        elide: Text.ElideRight
                                        Layout.fillWidth: true
                                    }
                                    MokaidLabel {
                                        text: "Level " + (card.modelData.agent_level || (card.modelData.agent && card.modelData.agent.level) || "—")
                                              + "  ·  " + (card.modelData.knowledge_item_count || 0) + " knowledge"
                                        color: "#8f9bb8"
                                        font.pixelSize: 11
                                        elide: Text.ElideRight
                                        Layout.fillWidth: true
                                    }
                                }
                            }
                            Item { Layout.fillHeight: true }
                            RowLayout {
                                Layout.fillWidth: true
                                Rectangle {
                                    radius: 8
                                    color: card.modelData.mode === "sale" ? "#1d3a2e" : "#2a2448"
                                    border.color: card.modelData.mode === "sale" ? "#3d8f6a" : "#6b5b95"
                                    implicitHeight: 24
                                    implicitWidth: badgeLabel.implicitWidth + 16
                                    MokaidLabel {
                                        id: badgeLabel
                                        anchors.centerIn: parent
                                        text: card.modelData.mode === "sale" ? "For sale" : "For rent"
                                        font.pixelSize: 11
                                        font.weight: Font.DemiBold
                                        color: card.modelData.mode === "sale" ? "#b7f0d4" : "#e4d9ff"
                                    }
                                }
                                Item { Layout.fillWidth: true }
                                MokaidLabel {
                                    text: root.priceLabel(card.modelData)
                                    font.pixelSize: 15
                                    font.weight: Font.DemiBold
                                    color: "#dbc3ff"
                                }
                            }
                        }
                    }
                }

                ColumnLayout {
                    visible: !features.busy && root.listings.length === 0
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.alignment: Qt.AlignHCenter
                    spacing: 6
                    MokaidIcon { name: "marketplace"; size: 28; color: Theme.primary; Layout.alignment: Qt.AlignHCenter }
                    MokaidLabel {
                        Layout.fillWidth: true
                        text: "Nothing is listed yet"
                        font.pixelSize: 16
                        font.weight: Font.DemiBold
                        horizontalAlignment: Text.AlignHCenter
                    }
                    MokaidLabel {
                        Layout.fillWidth: true
                        text: "When an agent reaches level 10, publish them from My agents."
                        color: Theme.secondary
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.Wrap
                    }
                }
            }

            Rectangle {
                visible: !!root.selectedListing.id
                Layout.preferredWidth: Math.min(360, parent.width * 0.38)
                Layout.fillHeight: true
                radius: 18
                color: root.panelSurface
                border.color: "#4a3d72"
                gradient: Gradient {
                    GradientStop { position: 0; color: "#1c1733" }
                    GradientStop { position: 1; color: "#10121b" }
                }
                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 18
                    spacing: 14
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 14
                        WorkforcePortrait {
                            agent: root.faceAgent(root.selectedListing.agent)
                            size: 72
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 4
                            MokaidLabel {
                                Layout.fillWidth: true
                                text: root.agentName(root.selectedListing)
                                font.pixelSize: 18
                                font.weight: Font.DemiBold
                                wrapMode: Text.Wrap
                            }
                            MokaidLabel {
                                Layout.fillWidth: true
                                text: root.roleTitle(root.selectedListing.agent) || "AI employee"
                                color: root.supportingText
                                font.pixelSize: 12
                                elide: Text.ElideRight
                            }
                        }
                    }
                    MokaidLabel {
                        Layout.fillWidth: true
                        text: root.priceLabel(root.selectedListing)
                        color: "#dbc3ff"
                        font.pixelSize: 22
                        font.weight: Font.DemiBold
                    }
                    MokaidLabel {
                        Layout.fillWidth: true
                        text: root.selectedListing.mode === "sale"
                              ? "You get your own copy of this agent and the knowledge linked to them. The seller keeps the original."
                              : (root.selectedListing.rent_billing === "subscription"
                                 ? "Monthly rental. Cancel anytime — access lasts through the period you already paid."
                                 : "A " + (root.selectedListing.fixed_days || 30) + "-day rental. Access ends when the term does.")
                        color: root.supportingText
                        font.pixelSize: 13
                        wrapMode: Text.Wrap
                    }
                    Rectangle {
                        Layout.fillWidth: true
                        radius: 12
                        color: "#161428"
                        border.color: "#322a4a"
                        implicitHeight: knowNote.implicitHeight + 20
                        MokaidLabel {
                            id: knowNote
                            anchors.fill: parent
                            anchors.margins: 12
                            text: (root.selectedListing.knowledge_item_count || 0) + " knowledge items come with the agent. Chats, tasks, Drive files and connectors stay with the seller."
                            color: "#c9d0e6"
                            font.pixelSize: 12
                            wrapMode: Text.Wrap
                        }
                    }
                    Item { Layout.fillHeight: true }
                    MokaidButton {
                        Layout.fillWidth: true
                        text: root.selectedListing.mode === "sale" ? "Buy this copy" : "Rent this agent"
                        highlighted: true
                        enabled: !features.busy && !!root.selectedListing.id
                        onClicked: root.openCheckout(root.selectedListing.id)
                    }
                }
            }
        }

        // My agents
        Flickable {
            visible: root.screen === "browse" && root.tab === "mine"
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: width
            contentHeight: mineColumn.implicitHeight
            clip: true
            ColumnLayout {
                id: mineColumn
                width: parent.width
                spacing: 12

                Rectangle {
                    Layout.fillWidth: true
                    radius: 16
                    color: "#161428"
                    border.color: "#4a3d72"
                    implicitHeight: hintRow.implicitHeight + 28
                    RowLayout {
                        id: hintRow
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.margins: 14
                        spacing: 12
                        Rectangle {
                            Layout.preferredWidth: 36
                            Layout.preferredHeight: 36
                            Layout.alignment: Qt.AlignTop
                            radius: 12
                            color: "#2a2150"
                            border.color: "#6b5b95"
                            MokaidIcon {
                                anchors.centerIn: parent
                                name: "bolt"
                                size: 16
                                color: "#dbc3ff"
                            }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 3
                            MokaidLabel {
                                text: "Level " + root.minLevel + " unlocks listing"
                                font.pixelSize: 14
                                font.weight: Font.DemiBold
                                color: "#f3eaff"
                            }
                            MokaidLabel {
                                Layout.fillWidth: true
                                text: root.mineHint
                                wrapMode: Text.Wrap
                                font.pixelSize: 12
                                color: "#d5c8f0"
                            }
                        }
                    }
                }

                RowLayout {
                    visible: root.mineSummary.total > 0
                    Layout.fillWidth: true
                    spacing: 10
                    StatChip { value: String(root.mineSummary.ready); label: "Ready to list"; accent: "#b7f0d4" }
                    StatChip { value: String(root.mineSummary.training); label: "Still training"; accent: "#f0c58b" }
                    StatChip { value: String(root.mineSummary.live); label: "On the market"; accent: "#dbc3ff" }
                }

                Repeater {
                    model: root.sortedMineRows
                    delegate: Rectangle {
                        id: mineCard
                        required property var modelData
                        Layout.fillWidth: true
                        radius: 18
                        color: "#12131f"
                        border.color: root.panelBorder
                        implicitHeight: mineInner.implicitHeight + 32
                        readonly property var agent: root.mineAgent(modelData)
                        readonly property bool eligible: !!modelData.eligible
                        readonly property bool locked: !eligible
                        readonly property int level: root.levelOf(modelData)

                        ColumnLayout {
                            id: mineInner
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.margins: 16
                            spacing: 14

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 14
                                Item {
                                    Layout.preferredWidth: 72
                                    Layout.preferredHeight: 72
                                    Layout.alignment: Qt.AlignTop
                                    WorkforcePortrait {
                                        anchors.centerIn: parent
                                        agent: mineCard.agent
                                        size: 68
                                    }
                                    Rectangle {
                                        visible: mineCard.locked
                                        width: 24
                                        height: 24
                                        radius: 12
                                        anchors.right: parent.right
                                        anchors.bottom: parent.bottom
                                        color: "#241c18"
                                        border.color: "#d7b07a"
                                        border.width: 1
                                        MokaidIcon {
                                            anchors.centerIn: parent
                                            name: "lock"
                                            size: 12
                                            color: "#f0c58b"
                                        }
                                    }
                                    Rectangle {
                                        visible: !mineCard.locked
                                        width: 14
                                        height: 14
                                        radius: 7
                                        anchors.right: parent.right
                                        anchors.bottom: parent.bottom
                                        anchors.margins: 2
                                        color: Theme.success
                                        border.color: "#12131f"
                                        border.width: 2
                                    }
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 4
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 8
                                        MokaidLabel {
                                            text: mineCard.agent.display_name || "Agent"
                                            font.pixelSize: 17
                                            font.weight: Font.DemiBold
                                            elide: Text.ElideRight
                                            Layout.fillWidth: true
                                        }
                                        Rectangle {
                                            visible: mineCard.locked
                                            radius: 8
                                            color: "#2a2218"
                                            border.color: "#8a6a3e"
                                            implicitHeight: 26
                                            implicitWidth: lockLabel.implicitWidth + 16
                                            MokaidLabel {
                                                id: lockLabel
                                                anchors.centerIn: parent
                                                text: (modelData.levels_remaining || 0) + (modelData.levels_remaining === 1 ? " level to go" : " levels to go")
                                                font.pixelSize: 11
                                                font.weight: Font.DemiBold
                                                color: "#f0c58b"
                                            }
                                        }
                                        Rectangle {
                                            visible: !mineCard.locked && !modelData.listing
                                            radius: 8
                                            color: "#1d3a2e"
                                            border.color: "#3d8f6a"
                                            implicitHeight: 26
                                            implicitWidth: readyLabel.implicitWidth + 16
                                            MokaidLabel {
                                                id: readyLabel
                                                anchors.centerIn: parent
                                                text: "Ready to list"
                                                font.pixelSize: 11
                                                font.weight: Font.DemiBold
                                                color: "#b7f0d4"
                                            }
                                        }
                                        Rectangle {
                                            visible: !!modelData.listing
                                            radius: 8
                                            color: root.listingStatus(modelData.listing) === "paused" ? "#2a2440" : "#1d3a2e"
                                            border.color: root.listingStatus(modelData.listing) === "paused" ? "#6b5b95" : "#3d8f6a"
                                            implicitHeight: 26
                                            implicitWidth: liveLabel.implicitWidth + 16
                                            MokaidLabel {
                                                id: liveLabel
                                                anchors.centerIn: parent
                                                text: root.listingStatus(modelData.listing) === "paused" ? "Paused" : "Live"
                                                font.pixelSize: 11
                                                font.weight: Font.DemiBold
                                                color: root.listingStatus(modelData.listing) === "paused" ? "#e4d9ff" : "#b7f0d4"
                                            }
                                        }
                                    }
                                    MokaidLabel {
                                        visible: root.roleTitle(mineCard.agent).length > 0
                                        text: root.roleTitle(mineCard.agent)
                                        color: root.supportingText
                                        font.pixelSize: 12
                                        elide: Text.ElideRight
                                        Layout.fillWidth: true
                                    }
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 8
                                        MokaidLabel {
                                            text: "Level " + mineCard.level
                                            font.pixelSize: 11
                                            font.weight: Font.DemiBold
                                            color: mineCard.locked ? "#f0c58b" : "#dbc3ff"
                                        }
                                        Rectangle {
                                            Layout.fillWidth: true
                                            Layout.preferredHeight: 8
                                            radius: 4
                                            color: "#1c1d2c"
                                            Rectangle {
                                                width: parent.width * root.levelRatio(modelData)
                                                height: parent.height
                                                radius: 4
                                                color: mineCard.locked ? "#c4a574" : "#8b5ded"
                                            }
                                        }
                                        MokaidLabel {
                                            text: mineCard.level + " / " + root.minLevel
                                            font.pixelSize: 11
                                            color: "#8f9bb8"
                                        }
                                    }
                                    MokaidLabel {
                                        text: (modelData.knowledge_item_count || 0) + ((modelData.knowledge_item_count === 1) ? " knowledge item" : " knowledge items")
                                        color: "#8f9bb8"
                                        font.pixelSize: 11
                                    }
                                }
                            }

                            MokaidLabel {
                                visible: mineCard.locked
                                Layout.fillWidth: true
                                text: "Keep sending this agent on missions. Listing opens automatically at level " + root.minLevel + "."
                                color: "#c9b89a"
                                font.pixelSize: 12
                                wrapMode: Text.Wrap
                            }

                            RowLayout {
                                visible: mineCard.eligible && !modelData.listing
                                Layout.fillWidth: true
                                spacing: 8
                                OfferChoice {
                                    title: "Sell copies"
                                    caption: "Review the terms, then publish"
                                    onClicked: root.openOffer(mineCard.agent.id, "sale")
                                    Accessible.name: "Sell copies of " + (mineCard.agent.display_name || "agent")
                                }
                                OfferChoice {
                                    title: "Rent out"
                                    caption: "Review the terms, then publish"
                                    onClicked: root.openOffer(mineCard.agent.id, "rent")
                                    Accessible.name: "Rent out " + (mineCard.agent.display_name || "agent")
                                }
                            }

                            RowLayout {
                                visible: !!modelData.listing
                                Layout.fillWidth: true
                                spacing: 12
                                MokaidLabel {
                                    text: root.priceLabel(modelData.listing)
                                    color: "#dbc3ff"
                                    font.pixelSize: 16
                                    font.weight: Font.DemiBold
                                }
                                MokaidLabel {
                                    text: modelData.listing && modelData.listing.mode === "sale" ? "Copies for sale" : "Available to rent"
                                    color: root.supportingText
                                    font.pixelSize: 12
                                    Layout.fillWidth: true
                                }
                                MokaidButton {
                                    text: root.listingStatus(modelData.listing) === "paused" ? "Resume" : "Pause listing"
                                    onClicked: root.toggleListing(modelData.listing)
                                }
                            }
                        }
                    }
                }

                ColumnLayout {
                    visible: !features.busy && root.mineRows.length === 0
                    Layout.fillWidth: true
                    Layout.topMargin: 24
                    spacing: 8
                    MokaidIcon { name: "agents"; size: 30; color: Theme.primary; Layout.alignment: Qt.AlignHCenter }
                    MokaidLabel {
                        Layout.fillWidth: true
                        text: "Your agents will show up here"
                        font.pixelSize: 16
                        font.weight: Font.DemiBold
                        horizontalAlignment: Text.AlignHCenter
                    }
                    MokaidLabel {
                        Layout.fillWidth: true
                        text: features.error || "Create an AI agent first. Once they reach level 10, you can sell a copy or rent them out."
                        color: Theme.secondary
                        wrapMode: Text.Wrap
                        horizontalAlignment: Text.AlignHCenter
                    }
                }
            }
        }

        // Earnings
        Flickable {
            visible: root.screen === "browse" && root.tab === "earnings"
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: width
            contentHeight: earnColumn.implicitHeight
            clip: true
            ColumnLayout {
                id: earnColumn
                width: parent.width
                spacing: 14

                Rectangle {
                    Layout.fillWidth: true
                    radius: 16
                    color: root.panelSurface
                    border.color: root.panelBorder
                    implicitHeight: connectCol.implicitHeight + 32
                    ColumnLayout {
                        id: connectCol
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: 16
                        spacing: 10
                        MokaidLabel { text: "Payouts"; font.pixelSize: 18; font.weight: Font.DemiBold }
                        MokaidLabel {
                            Layout.fillWidth: true
                            text: root.earningsData.connect_ready
                                  ? "Stripe Connect is ready. You earn " + (100 - (root.earningsData.fee_percent || 15)) + "% of each sale and rental."
                                  : "Connect Stripe before publishing. Mokaid keeps " + (root.earningsData.fee_percent || 15) + "% of every payment."
                            color: root.supportingText
                            wrapMode: Text.Wrap
                            font.pixelSize: 13
                        }
                        RowLayout {
                            visible: !root.earningsData.connect_ready
                            MokaidTextField {
                                Layout.preferredWidth: 80
                                text: root.connectCountry
                                onTextChanged: root.connectCountry = text.toUpperCase()
                                placeholderText: "US"
                                Accessible.name: "Payout country"
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
                            radius: 14
                            color: root.panelSurface
                            border.color: root.panelBorder
                            implicitHeight: 88
                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 16
                                spacing: 6
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
                        id: earnRow
                        required property var modelData
                        Layout.fillWidth: true
                        radius: 14
                        color: root.panelSurface
                        border.color: root.panelBorder
                        implicitHeight: 72
                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: 12
                            spacing: 12
                            WorkforcePortrait {
                                agent: root.faceAgent(earnRow.modelData.agent)
                                size: 44
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2
                                MokaidLabel {
                                    Layout.fillWidth: true
                                    text: root.agentName(earnRow.modelData)
                                    elide: Text.ElideRight
                                    font.weight: Font.DemiBold
                                }
                                MokaidLabel {
                                    text: earnRow.modelData.status === "paused" ? "Paused" : "Live"
                                    color: root.supportingText
                                    font.pixelSize: 11
                                }
                            }
                            MokaidLabel { text: root.priceLabel(earnRow.modelData); color: "#dbc3ff"; font.weight: Font.DemiBold }
                        }
                    }
                }
            }
        }

        Flickable {
            id: offerPage
            objectName: "offerPage"
            visible: root.screen === "publish"
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: width
            contentHeight: offerHolder.height
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            Item {
                id: offerHolder
                width: offerPage.width
                height: offerColumn.implicitHeight
            ColumnLayout {
                id: offerColumn
                width: Math.min(parent.width, 880)
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 18

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 4
                    AbstractButton {
                        id: crumbMarket
                        implicitHeight: 32
                        implicitWidth: crumbMarketLabel.implicitWidth + 8
                        hoverEnabled: true
                        Accessible.name: "Back to Marketplace"
                        onClicked: root.closeOffer("discover")
                        background: Rectangle { color: crumbMarket.hovered ? "#1c1a2e" : "transparent"; radius: 8 }
                        contentItem: MokaidLabel {
                            id: crumbMarketLabel
                            text: "Marketplace"
                            font.pixelSize: 13
                            color: crumbMarket.hovered ? "#f4ecff" : "#b4a6d4"
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                    MokaidIcon { name: "chevron-right"; size: 12; color: "#6d7896" }
                    AbstractButton {
                        id: crumbMine
                        implicitHeight: 32
                        implicitWidth: crumbMineLabel.implicitWidth + 8
                        hoverEnabled: true
                        Accessible.name: "Back to My agents"
                        onClicked: root.closeOffer("mine")
                        background: Rectangle { color: crumbMine.hovered ? "#1c1a2e" : "transparent"; radius: 8 }
                        contentItem: MokaidLabel {
                            id: crumbMineLabel
                            text: "My agents"
                            font.pixelSize: 13
                            color: crumbMine.hovered ? "#f4ecff" : "#b4a6d4"
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                    MokaidIcon { name: "chevron-right"; size: 12; color: "#6d7896" }
                    MokaidLabel {
                        text: root.publishAgent.display_name || "Agent"
                        font.pixelSize: 13
                        color: "#b4a6d4"
                        elide: Text.ElideRight
                        Layout.maximumWidth: 220
                    }
                    MokaidIcon { name: "chevron-right"; size: 12; color: "#6d7896" }
                    MokaidLabel {
                        text: root.offerTitle
                        font.pixelSize: 13
                        font.weight: Font.DemiBold
                        color: Theme.text
                    }
                    Item { Layout.fillWidth: true }
                }

                Rectangle {
                    Layout.fillWidth: true
                    radius: 18
                    color: "#141322"
                    border.color: "#4a3d72"
                    implicitHeight: heroRow.implicitHeight + 36
                    RowLayout {
                        id: heroRow
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: 18
                        spacing: 16
                        WorkforcePortrait {
                            agent: root.publishAgent
                            size: 84
                            Layout.alignment: Qt.AlignTop
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 6
                            MokaidLabel {
                                text: root.offerTitle
                                font.pixelSize: 12
                                font.weight: Font.DemiBold
                                color: "#dbc3ff"
                            }
                            MokaidLabel {
                                text: root.publishAgent.display_name || "Agent"
                                font.pixelSize: 26
                                font.weight: Font.DemiBold
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                            }
                            MokaidLabel {
                                visible: root.roleTitle(root.publishAgent).length > 0
                                text: root.roleTitle(root.publishAgent)
                                color: root.supportingText
                                font.pixelSize: 14
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                            }
                            Flow {
                                Layout.fillWidth: true
                                spacing: 8
                                Rectangle {
                                    radius: 8
                                    color: "#2a2150"
                                    border.color: "#6b5b95"
                                    implicitHeight: 26
                                    implicitWidth: levelChip.implicitWidth + 16
                                    MokaidLabel {
                                        id: levelChip
                                        anchors.centerIn: parent
                                        text: "Level " + root.levelOf(root.publishRow)
                                        font.pixelSize: 11
                                        font.weight: Font.DemiBold
                                        color: "#e4d9ff"
                                    }
                                }
                                Rectangle {
                                    radius: 8
                                    color: "#1d3a2e"
                                    border.color: "#3d8f6a"
                                    implicitHeight: 26
                                    implicitWidth: knowChip.implicitWidth + 16
                                    MokaidLabel {
                                        id: knowChip
                                        anchors.centerIn: parent
                                        text: (root.publishRow.knowledge_item_count || 0) + " knowledge"
                                        font.pixelSize: 11
                                        font.weight: Font.DemiBold
                                        color: "#b7f0d4"
                                    }
                                }
                                Rectangle {
                                    visible: !!(root.publishAgent.status)
                                    radius: 8
                                    color: "#17182a"
                                    border.color: "#2e3148"
                                    implicitHeight: 26
                                    implicitWidth: statusChip.implicitWidth + 16
                                    MokaidLabel {
                                        id: statusChip
                                        anchors.centerIn: parent
                                        text: root.titleCase(root.publishAgent.status)
                                        font.pixelSize: 11
                                        color: "#c9d0e6"
                                    }
                                }
                                Rectangle {
                                    visible: !!(root.publishAgent.model_quality)
                                    radius: 8
                                    color: "#17182a"
                                    border.color: "#2e3148"
                                    implicitHeight: 26
                                    implicitWidth: modelChip.implicitWidth + 16
                                    MokaidLabel {
                                        id: modelChip
                                        anchors.centerIn: parent
                                        text: root.titleCase(root.publishAgent.model_quality)
                                        font.pixelSize: 11
                                        color: "#c9d0e6"
                                    }
                                }
                            }
                        }
                    }
                }

                MokaidLabel { text: "Agent"; font.pixelSize: 16; font.weight: Font.DemiBold }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    StatChip { value: String(root.levelOf(root.publishRow)); label: "Level"; accent: "#dbc3ff" }
                    StatChip { value: String(root.publishAgent.missions_completed || 0); label: "Missions"; accent: "#9ecbff" }
                    StatChip { value: String(root.publishRow.knowledge_item_count || 0); label: "Knowledge"; accent: "#b7f0d4" }
                    StatChip { value: root.publishAgent.department || "—"; label: "Department"; accent: "#f0c58b" }
                }
                Flow {
                    Layout.fillWidth: true
                    spacing: 8
                    visible: root.skillNames(root.publishAgent).length > 0
                    Repeater {
                        model: root.skillNames(root.publishAgent)
                        Rectangle {
                            required property string modelData
                            radius: 8
                            color: "#1a1830"
                            border.color: "#3d3458"
                            implicitHeight: 28
                            implicitWidth: skillLabel.implicitWidth + 18
                            MokaidLabel {
                                id: skillLabel
                                anchors.centerIn: parent
                                text: modelData
                                font.pixelSize: 12
                                color: "#e4d9ff"
                            }
                        }
                    }
                }
                MokaidLabel {
                    visible: root.skillNames(root.publishAgent).length === 0
                    text: "No skills are listed on this agent yet."
                    color: "#8f9bb8"
                    font.pixelSize: 12
                }

                MokaidLabel {
                    text: root.publishMode === "sale" ? "What a buyer receives" : "What a renter receives"
                    font.pixelSize: 16
                    font.weight: Font.DemiBold
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        radius: 16
                        color: root.panelSurface
                        border.color: "#3d8f6a"
                        implicitHeight: includedCol.implicitHeight + 28
                        ColumnLayout {
                            id: includedCol
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.margins: 14
                            spacing: 8
                            MokaidLabel { text: "Included"; font.pixelSize: 13; font.weight: Font.DemiBold; color: "#b7f0d4" }
                            MokaidLabel {
                                Layout.fillWidth: true
                                wrapMode: Text.Wrap
                                color: "#d5deef"
                                font.pixelSize: 13
                                text: "Their own copy of " + (root.publishAgent.display_name || "this agent") + ", with the same portrait, role, skills and level."
                            }
                            MokaidLabel {
                                Layout.fillWidth: true
                                wrapMode: Text.Wrap
                                color: "#d5deef"
                                font.pixelSize: 13
                                text: (root.publishRow.knowledge_item_count || 0) + " knowledge items linked to this agent, including the material those items are built from."
                            }
                            MokaidLabel {
                                visible: root.publishMode === "rent"
                                Layout.fillWidth: true
                                wrapMode: Text.Wrap
                                color: "#d5deef"
                                font.pixelSize: 13
                                text: root.publishRentBilling === "subscription"
                                      ? "Access renews every month until they cancel. It lasts through the period already paid."
                                      : "Access lasts " + root.publishFixedDays + " days, then ends."
                            }
                        }
                    }
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        radius: 16
                        color: root.panelSurface
                        border.color: "#8a6a3e"
                        implicitHeight: privateCol.implicitHeight + 28
                        ColumnLayout {
                            id: privateCol
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.margins: 14
                            spacing: 8
                            MokaidLabel { text: "Stays in your workspace"; font.pixelSize: 13; font.weight: Font.DemiBold; color: "#f0c58b" }
                            MokaidLabel { Layout.fillWidth: true; wrapMode: Text.Wrap; color: "#d5deef"; font.pixelSize: 13; text: "The original agent. Buyers never take over the one you already have." }
                            MokaidLabel { Layout.fillWidth: true; wrapMode: Text.Wrap; color: "#d5deef"; font.pixelSize: 13; text: "Conversations, tasks, Drive files and installed connectors." }
                            MokaidLabel { Layout.fillWidth: true; wrapMode: Text.Wrap; color: "#d5deef"; font.pixelSize: 13; text: "You can pause the listing later. Copies already delivered stay with their owners." }
                        }
                    }
                }

                MokaidLabel { text: "Commercial terms"; font.pixelSize: 16; font.weight: Font.DemiBold }
                Rectangle {
                    Layout.fillWidth: true
                    radius: 16
                    color: root.panelSurface
                    border.color: root.panelBorder
                    implicitHeight: termsCol.implicitHeight + 28
                    ColumnLayout {
                        id: termsCol
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: 14
                        spacing: 8
                        MokaidLabel {
                            Layout.fillWidth: true
                            wrapMode: Text.Wrap
                            font.pixelSize: 13
                            color: "#d5deef"
                            text: root.publishMode === "sale"
                                  ? "Each purchase creates one more copy. There is no cap on how many people can buy."
                                  : "Each rental creates a copy for the term you choose. When the term ends, that access ends."
                        }
                        MokaidLabel {
                            Layout.fillWidth: true
                            wrapMode: Text.Wrap
                            font.pixelSize: 13
                            color: "#d5deef"
                            text: "You set the price in USD. The minimum is 1.00. Mokaid keeps " + root.feePercent + "% and Stripe Connect pays you the rest."
                        }
                        MokaidLabel {
                            Layout.fillWidth: true
                            wrapMode: Text.Wrap
                            font.pixelSize: 13
                            color: "#d5deef"
                            text: "The listing goes live as soon as you publish. New buyers can find it under Discover."
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.bottomMargin: 8
                    radius: 18
                    color: "#161428"
                    border.color: "#6b5b95"
                    implicitHeight: publishCol.implicitHeight + 36
                    ColumnLayout {
                        id: publishCol
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: 18
                        spacing: 12
                        MokaidLabel {
                            text: root.publishMode === "sale" ? "Publish copies for sale" : "Publish the rental"
                            font.pixelSize: 18
                            font.weight: Font.DemiBold
                        }
                        MokaidLabel {
                            visible: root.publishMode === "rent"
                            text: "How long does access last?"
                            color: root.supportingText
                            font.pixelSize: 12
                        }
                        RowLayout {
                            visible: root.publishMode === "rent"
                            Layout.fillWidth: true
                            spacing: 8
                            Repeater {
                                model: [
                                    { id: "subscription", days: 0, label: "Monthly" },
                                    { id: "fixed", days: 7, label: "7 days" },
                                    { id: "fixed", days: 30, label: "30 days" },
                                    { id: "fixed", days: 90, label: "90 days" }
                                ]
                                AbstractButton {
                                    id: termBtn
                                    required property var modelData
                                    implicitHeight: 34
                                    implicitWidth: termLabel.implicitWidth + 22
                                    hoverEnabled: true
                                    readonly property bool selected: modelData.id === "subscription"
                                        ? root.publishRentBilling === "subscription"
                                        : root.publishRentBilling === "fixed" && root.publishFixedDays === modelData.days
                                    onClicked: {
                                        root.publishRentBilling = modelData.id
                                        if (modelData.days) root.publishFixedDays = modelData.days
                                    }
                                    background: Rectangle {
                                        radius: 8
                                        color: termBtn.selected ? "#2a2444" : "transparent"
                                        border.color: termBtn.selected ? "#8b5ded" : root.panelBorder
                                    }
                                    contentItem: MokaidLabel {
                                        id: termLabel
                                        text: termBtn.modelData.label
                                        font.pixelSize: 12
                                        font.weight: termBtn.selected ? Font.DemiBold : Font.Normal
                                        horizontalAlignment: Text.AlignHCenter
                                        verticalAlignment: Text.AlignVCenter
                                        color: termBtn.selected ? Theme.text : Theme.secondary
                                    }
                                }
                            }
                            Item { Layout.fillWidth: true }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            MokaidLabel { text: "Price"; color: Theme.secondary; font.pixelSize: 13 }
                            MokaidTextField {
                                Layout.preferredWidth: 140
                                text: root.publishPrice
                                onTextChanged: root.publishPrice = text
                                Accessible.name: "Price in USD"
                            }
                            MokaidLabel { text: "USD"; color: "#8f9bb8"; font.pixelSize: 13 }
                            Item { Layout.fillWidth: true }
                        }
                        MokaidLabel {
                            Layout.fillWidth: true
                            wrapMode: Text.Wrap
                            font.pixelSize: 13
                            color: root.priceValid ? "#dbc3ff" : "#f0c58b"
                            text: root.priceValid
                                  ? "Buyer pays " + root.money(root.payout.gross, "usd")
                                    + ". You receive " + root.money(root.payout.net, "usd")
                                    + " after the " + root.feePercent + "% fee."
                                  : "Enter at least USD 1.00."
                        }
                        MokaidLabel {
                            visible: features.error.length > 0
                            Layout.fillWidth: true
                            wrapMode: Text.Wrap
                            font.pixelSize: 13
                            color: Theme.danger
                            text: features.error
                        }
                        MokaidButton {
                            Layout.fillWidth: true
                            text: root.publishPending && features.busy
                                  ? "Publishing…"
                                  : (root.publishMode === "sale" ? "Publish on the marketplace" : "Publish rental on the marketplace")
                            highlighted: true
                            enabled: root.priceValid && !features.busy
                            Accessible.name: "Publish on the marketplace"
                            onClicked: root.confirmPublish()
                        }
                    }
                }
            }
            }
        }
    }
}
