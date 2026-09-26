pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root
    required property var controller
    readonly property bool searching: controller.tab === "search"
    readonly property bool categoryPage: controller.tab === "categories"

    component FilterOption: CheckBox {
        id: check
        font.family: Theme.fontFamily; font.pixelSize: 12
        implicitHeight: 30
        spacing: 9
        contentItem: MokaidLabel { text: check.text; font: check.font; leftPadding: 25; verticalAlignment: Text.AlignVCenter; color: Theme.secondary }
        indicator: Rectangle {
            x: 0; y: (check.height - height) / 2; width: 15; height: 15; radius: 4
            color: check.checked ? "#8539f4" : "transparent"
            border.color: check.visualFocus ? Theme.focusBorder : check.checked ? "#b783ff" : "#7983a4"
            MokaidIcon { anchors.centerIn: parent; name: "check"; size: 11; color: "white"; visible: check.checked }
        }
    }
    component CategoryChip: MokaidButton {
        id: chip
        property string categoryId: "all"
        implicitHeight: 36; font.pixelSize: 11
        highlighted: root.controller.categoryFilter === categoryId
        onClicked: { root.controller.categoryFilter = categoryId; root.controller.tab = "search" }
    }

    RowLayout {
        anchors.fill: parent; spacing: 24
        Rectangle {
            visible: root.searching
            Layout.preferredWidth: root.width < 850 ? 165 : 190
            Layout.fillHeight: true
            radius: 12; color: "#0e101a"; border.color: "#25273b"
            Flickable {
                anchors.fill: parent; anchors.margins: 16; clip: true
                contentHeight: filters.implicitHeight; contentWidth: width
                ScrollBar.vertical: ScrollBar {}
                ColumnLayout {
                    id: filters; width: parent.width; spacing: 16
                    RowLayout {
                        Layout.fillWidth: true
                        MokaidLabel { text: "Filters"; font.weight: Font.Bold; Layout.fillWidth: true }
                        MokaidButton { text: "Clear all"; implicitWidth: 55; leftPadding: 0; rightPadding: 0; implicitHeight: 28; quiet: true; font.pixelSize: 10; onClicked: root.controller.clearFilters() }
                    }
                    MokaidLabel { text: "Price range"; font.pixelSize: 12 }
                    Slider {
                        id: priceSlider
                        objectName: "marketplacePriceFilter"
                        Layout.fillWidth: true; from: 0; to: 500; stepSize: 5
                        value: root.controller.maxPrice
                        Accessible.name: "Maximum price"
                        onMoved: root.controller.maxPrice = value
                        background: Rectangle { x: priceSlider.leftPadding; y: priceSlider.topPadding + priceSlider.availableHeight / 2 - 2; width: priceSlider.availableWidth; height: 3; radius: 2; color: "#383048"; Rectangle { width: priceSlider.visualPosition * parent.width; height: 3; radius: 2; color: "#a35bff" } }
                        handle: Rectangle { x: priceSlider.leftPadding + priceSlider.visualPosition * (priceSlider.availableWidth - width); y: priceSlider.topPadding + priceSlider.availableHeight / 2 - height / 2; width: 12; height: 12; radius: 6; color: "#ac75ff"; border.color: priceSlider.visualFocus ? "white" : "#cdaaff" }
                    }
                    RowLayout { Layout.fillWidth: true; MokaidLabel { text: "$0"; color: Theme.secondary; font.pixelSize: 11 }
Item { Layout.fillWidth: true }
MokaidLabel { text: "$" + root.controller.maxPrice + (root.controller.maxPrice === 500 ? "+" : ""); color: Theme.secondary; font.pixelSize: 11 } }
                    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.divider }
                    MokaidLabel { text: "Type"; font.pixelSize: 12 }
                    ColumnLayout {
                        spacing: 2
                        FilterOption { text: "For sale"; checked: root.controller.modeFilter === "sale"; onClicked: root.controller.modeFilter = checked ? "sale" : "all" }
                        FilterOption { text: "For rent"; checked: root.controller.modeFilter === "rent"; onClicked: root.controller.modeFilter = checked ? "rent" : "all" }
                        FilterOption { text: "Saved agents"; checked: root.controller.savedOnly; onClicked: root.controller.savedOnly = checked }
                    }
                    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.divider }
                    MokaidLabel { text: "Category"; font.pixelSize: 12 }
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 2
                        Repeater {
                            model: root.controller.categories
                            FilterOption {
                                required property var modelData
                                Layout.fillWidth: true
                                text: modelData.label
                                checked: root.controller.categoryFilter === modelData.id
                                onClicked: root.controller.categoryFilter = checked ? modelData.id : "all"
                            }
                        }
                    }
                }
            }
        }
        Flickable {
            id: scroll
            Layout.fillWidth: true; Layout.fillHeight: true; clip: true
            contentWidth: width; contentHeight: content.implicitHeight + 12
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            ColumnLayout {
                id: content; width: scroll.width - 10; spacing: 24
                Rectangle {
                    visible: !root.searching && !root.categoryPage
                    Layout.fillWidth: true; implicitHeight: Math.max(200, Math.min(228, width * .23))
                    radius: 12; color: "#080a19"; border.color: "#6937b5"; clip: true
                    Image {
                        anchors.top: parent.top; anchors.bottom: parent.bottom; anchors.right: parent.right
                        width: Math.min(parent.width, parent.height * 3)
                        source: "qrc:/ui/marketplace-hero.png"; fillMode: Image.PreserveAspectFit; asynchronous: true
                    }
                    Rectangle { anchors.fill: parent; radius: 12; color: "transparent"; border.color: "#6937b5" }
                    ColumnLayout {
                        anchors.left: parent.left; anchors.leftMargin: 30; anchors.verticalCenter: parent.verticalCenter
                        width: parent.width * .58; spacing: 12
                        MokaidLabel { text: "AI agents\nfor a more productive\ntomorrow."; font.pixelSize: root.width < 850 ? 28 : 34; font.weight: Font.Bold; lineHeight: 1.04; Layout.fillWidth: true }
                        MokaidLabel { text: "Ready-to-use agents built by creators. No code. Instant impact."; color: "#d0c7e9"; font.pixelSize: 12; wrapMode: Text.Wrap; Layout.maximumWidth: 370; Layout.fillWidth: true }
                    }
                }
                Flow {
                    visible: !root.searching && !root.categoryPage
                    Layout.fillWidth: true; spacing: 8
                    CategoryChip { categoryId: "all"; text: "All"; iconName: "marketplace" }
                    Repeater {
                        model: root.controller.categories.slice(0, 5)
                        CategoryChip { required property var modelData; categoryId: modelData.id; text: modelData.label; iconName: modelData.icon }
                    }
                    MokaidButton { text: "More"; iconName: "chevron-down"; implicitHeight: 36; font.pixelSize: 11; onClicked: root.controller.tab = "categories" }
                }
                GridLayout {
                    visible: root.categoryPage
                    Layout.fillWidth: true; columns: width > 650 ? 3 : 2; uniformCellWidths: true; columnSpacing: 14; rowSpacing: 14
                    Repeater {
                        model: root.controller.categories
                        AbstractButton {
                            id: category
                            required property var modelData
                            objectName: "marketplaceCategory-" + modelData.id
                            Layout.fillWidth: true; Layout.preferredHeight: Math.max(132, Math.min(172, (root.height - 54) / 4))
                            hoverEnabled: true
                            Accessible.name: modelData.label + ", " + root.controller.categoryCount(modelData.id) + " agents"
                            onClicked: { root.controller.categoryFilter = modelData.id; root.controller.tab = "search" }
                            background: Rectangle { radius: 12; color: category.hovered ? "#191728" : "#11131e"; border.color: category.visualFocus ? Theme.focusBorder : category.hovered ? "#655080" : "#24273a" }
                            contentItem: ColumnLayout {
                                anchors.fill: parent; anchors.margins: 20; spacing: 9
                                Rectangle {
                                    implicitWidth: 52; implicitHeight: 52; radius: 12
                                    property color tint: category.modelData.accent
                                    color: Qt.rgba(tint.r, tint.g, tint.b, .10)
                                    // Hex strings are normalized through the icon's color property.
                                    MokaidIcon { anchors.centerIn: parent; name: category.modelData.icon; color: category.modelData.accent; size: 29 }
                                }
                                Item { Layout.fillHeight: true }
                                MokaidLabel { text: category.modelData.label; font.pixelSize: 15; font.weight: Font.DemiBold; Layout.fillWidth: true; elide: Text.ElideRight }
                                MokaidLabel { text: root.controller.categoryCount(category.modelData.id) + (root.controller.categoryCount(category.modelData.id) === 1 ? " agent" : " agents"); color: Theme.muted; font.pixelSize: 12 }
                            }
                        }
                    }
                }
                RowLayout {
                    visible: root.searching; Layout.fillWidth: true; spacing: 10
                    MokaidTextField {
                        id: searchField; objectName: "marketplaceSearch"; Layout.fillWidth: true
                        placeholderText: "Search agents, skills, or use cases…"
                        Accessible.name: "Search marketplace"
                        text: root.controller.queryText
                        onTextEdited: root.controller.queryText = text
                        onAccepted: root.controller.queryText = text
                    }
                    MokaidButton { text: "Search"; highlighted: true; onClicked: root.controller.queryText = searchField.text }
                }
                RowLayout {
                    visible: !root.categoryPage; Layout.fillWidth: true; spacing: 8
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 4
                        MokaidLabel { text: root.searching ? root.controller.listings.length + " agents found" : "Featured agents"; font.pixelSize: root.searching ? 13 : 19; font.weight: Font.DemiBold }
                        MokaidLabel { visible: !root.searching; text: "Discover your next AI teammate"; color: Theme.muted; font.pixelSize: 12 }
                    }
                    Item { visible: !root.searching; Layout.fillWidth: true }
                    MokaidButton { visible: !root.searching; text: "View all"; iconName: "arrow-right"; quiet: true; implicitHeight: 32; onClicked: root.controller.tab = "search" }
                    MokaidComboBox { visible: root.searching; implicitHeight: 34; Layout.preferredWidth: 155; model: ["Most recent", "Price: low to high", "Price: high to low", "Name: A–Z"]; currentIndex: root.controller.sortOrder; onActivated: root.controller.sortOrder = currentIndex; Accessible.name: "Sort agents" }
                    MokaidButton { visible: root.searching; iconName: "grid"; implicitHeight: 34; implicitWidth: 34; highlighted: !root.controller.listView; Accessible.name: "Grid view"; onClicked: root.controller.listView = false }
                    MokaidButton { visible: root.searching; iconName: "list"; implicitHeight: 34; implicitWidth: 34; highlighted: root.controller.listView; Accessible.name: "List view"; onClicked: root.controller.listView = true }
                }
                GridLayout {
                    id: cards
                    visible: !root.categoryPage && root.controller.listings.length > 0
                    Layout.fillWidth: true
                    columns: root.controller.listView && root.searching ? 1 : width >= 920 ? 4 : width >= 640 ? 3 : 2
                    columnSpacing: 14; rowSpacing: 14
                    Repeater {
                        model: root.searching ? root.controller.listings : root.controller.listings.slice(0, 8)
                        MarketplaceCard {
                            required property var modelData
                            listing: modelData; controller: root.controller
                            compact: root.controller.listView && root.searching
                            Layout.fillWidth: true; Layout.minimumWidth: 0
                        }
                    }
                }
                Rectangle {
                    visible: !root.categoryPage && root.controller.listings.length === 0
                    Layout.fillWidth: true; implicitHeight: 238; radius: 12; color: "#10121d"; border.color: "#24273a"
                    ColumnLayout {
                        anchors.centerIn: parent; width: parent.width - 48; spacing: 14
                        MokaidIcon { name: "marketplace"; color: Theme.primary; size: 32; Layout.alignment: Qt.AlignHCenter }
                        MokaidLabel { text: features.busy ? "Loading agents…" : root.searching ? "No agents match your filters" : "Your next teammate is on the way"; font.pixelSize: 18; font.weight: Font.DemiBold; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap }
                        MokaidLabel { text: features.busy ? "Getting the latest marketplace listings." : root.searching ? "Try another skill, category or price range." : "Publish a trained agent to be among the first creators on the marketplace."; color: Theme.secondary; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; Layout.fillWidth: true; wrapMode: Text.Wrap }
                        MokaidButton { visible: !features.busy; text: root.searching ? "Clear filters" : "My listings"; onClicked: root.searching ? root.controller.clearFilters() : root.controller.showBrowse("mine"); Layout.alignment: Qt.AlignHCenter }
                    }
                }
                MokaidButton { visible: features.hasMore && !root.categoryPage; text: features.busy ? "Loading…" : "Load more agents"; enabled: !features.busy; Layout.alignment: Qt.AlignHCenter; onClicked: features.loadMore() }
            }
        }
    }
}
