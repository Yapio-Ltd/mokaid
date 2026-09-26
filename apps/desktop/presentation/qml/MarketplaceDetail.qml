pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root
    required property var controller
    readonly property var listing: controller.selectedListing || ({})
    readonly property var agent: listing.agent || ({})
    readonly property bool checkout: controller.screen === "checkout"
    readonly property bool success: controller.screen === "success"
    readonly property string agentName: controller.agentName(listing)
    readonly property var skills: controller.skillNames(agent)
    readonly property string terms: listing.mode === "sale"
        ? "Your own copy of this agent, with their skills and linked knowledge. The creator keeps the original."
        : listing.rent_billing === "subscription"
            ? "Monthly access to this agent. Cancel anytime; access continues until the end of your paid period."
            : "Access for " + (listing.fixed_days || 30) + " days, including the agent’s skills and linked knowledge."

    component Panel: Rectangle {
        radius: 12; color: "#11131e"; border.color: "#282b40"
    }
    component Benefit: RowLayout {
        id: benefit
        property string text: ""
        spacing: 10
        MokaidIcon { name: "check"; size: 15; color: "#77e8d8"; Layout.alignment: Qt.AlignTop }
        MokaidLabel { text: benefit.text; color: Theme.secondary; font.pixelSize: 12; Layout.fillWidth: true; wrapMode: Text.Wrap }
    }

    Flickable {
        id: scroll; anchors.fill: parent; clip: true
        contentWidth: width; contentHeight: body.implicitHeight + 16
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
        ColumnLayout {
            id: body; width: scroll.width - 10; spacing: 22
            MokaidButton {
                objectName: "marketplaceBack"; visible: !root.success
                text: root.checkout ? "Back to " + root.agentName : "Back to marketplace"
                iconName: "chevron-left"; quiet: true; implicitHeight: 32; font.pixelSize: 12; leftPadding: 0
                onClicked: root.checkout ? root.controller.screen = "detail" : root.controller.showBrowse("discover")
            }
            ColumnLayout {
                visible: !root.checkout && !root.success
                Layout.fillWidth: true; spacing: 22
                RowLayout {
                    Layout.fillWidth: true; spacing: 24
                    WorkforcePortrait { agent: root.controller.faceAgent(root.agent); size: 120; Layout.alignment: Qt.AlignTop }
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 9
                        MokaidLabel { text: root.agentName; font.pixelSize: 30; font.weight: Font.Bold; Layout.fillWidth: true; elide: Text.ElideRight }
                        MokaidLabel { text: root.controller.roleTitle(root.agent) || "AI assistant"; color: Theme.secondary; font.pixelSize: 14 }
                        RowLayout {
                            spacing: 8
                            MokaidIcon { name: "shield"; color: "#c295ff"; size: 16 }
                            MokaidLabel { text: root.controller.categoryName(root.controller.categoryOf(root.listing)); font.pixelSize: 12; color: Theme.secondary }
                            MokaidLabel { text: "·  Level " + (root.listing.agent_level || root.agent.level || 1); font.pixelSize: 12; color: "#ffbd57" }
                        }
                        MokaidLabel { text: root.listing.description || root.terms; color: Theme.secondary; font.pixelSize: 13; Layout.fillWidth: true; Layout.maximumWidth: 760; wrapMode: Text.Wrap; lineHeight: 1.25 }
                    }
                }
                RowLayout {
                    Layout.fillWidth: true; spacing: 12
                    MokaidButton {
                        objectName: "marketplaceBuy"
                        text: (root.listing.mode === "sale" ? "Buy for " : "Rent for ") + root.controller.priceLabel(root.listing)
                        highlighted: true; Layout.preferredWidth: 275; enabled: !!root.listing.id && !features.busy && !features.offline
                        onClicked: root.controller.beginCheckout()
                    }
                    MokaidButton { iconName: "heart"; highlighted: root.controller.savedIds.indexOf(root.listing.id) >= 0; Accessible.name: highlighted ? "Remove saved agent" : "Save agent"; onClicked: root.controller.toggleSaved(root.listing.id) }
                    Item { Layout.fillWidth: true }
                }
                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                    Repeater {
                        model: ["Overview", "Capabilities", "Integrations", "Reviews", "Support"]
                        MokaidButton { required property string modelData; text: modelData; implicitHeight: 36; font.pixelSize: 12; highlighted: root.controller.detailTab === modelData; onClicked: root.controller.detailTab = modelData }
                    }
                    Item { Layout.fillWidth: true }
                }
                RowLayout {
                    visible: root.controller.detailTab === "Overview"
                    Layout.fillWidth: true; spacing: 16
                    Panel {
                        Layout.fillWidth: true; Layout.preferredHeight: 252
                        border.color: "#644090"; clip: true
                        Image { anchors.fill: parent; source: "qrc:/ui/marketplace-hero.png"; opacity: .25; fillMode: Image.PreserveAspectCrop }
                        ColumnLayout {
                            anchors.centerIn: parent; width: parent.width - 32; spacing: 12
                            WorkforcePortrait { agent: root.controller.faceAgent(root.agent); size: 84; Layout.alignment: Qt.AlignHCenter }
                            MokaidLabel { text: "Meet " + root.agentName; font.pixelSize: 18; font.weight: Font.DemiBold; Layout.alignment: Qt.AlignHCenter }
                            MokaidButton { text: "Explore capabilities"; iconName: "arrow-right"; quiet: true; implicitHeight: 32; Layout.alignment: Qt.AlignHCenter; onClicked: root.controller.detailTab = "Capabilities" }
                        }
                    }
                    Panel {
                        Layout.fillWidth: true; Layout.preferredHeight: 252
                        ColumnLayout {
                            anchors.fill: parent; anchors.margins: 22; spacing: 14
                            MokaidLabel { text: "Key features"; font.pixelSize: 15; font.weight: Font.Bold }
                            Repeater { model: root.skills.slice(0, 4); Benefit { required property string modelData; text: modelData; Layout.fillWidth: true } }
                            Benefit { text: (root.listing.knowledge_item_count || 0) + " linked knowledge items included"; Layout.fillWidth: true }
                            Benefit { text: root.listing.mode === "sale" ? "Your own independent agent copy" : "Ready to work in your workspace"; Layout.fillWidth: true }
                            Item { Layout.fillHeight: true }
                        }
                    }
                }
                Panel {
                    visible: root.controller.detailTab === "Capabilities"
                    Layout.fillWidth: true; implicitHeight: capabilityColumn.implicitHeight + 44
                    ColumnLayout {
                        id: capabilityColumn; anchors.fill: parent; anchors.margins: 22; spacing: 16
                        MokaidLabel { text: "What " + root.agentName + " can do"; font.pixelSize: 19; font.weight: Font.DemiBold }
                        Repeater { model: root.skills; Benefit { required property string modelData; text: modelData; Layout.fillWidth: true } }
                        MokaidLabel { visible: root.skills.length === 0; text: "The creator has not listed individual skills yet."; font.pixelSize: 13; color: Theme.secondary }
                        MokaidLabel { text: (root.listing.knowledge_item_count || 0) + " knowledge items are included with this agent. Your new agent works with the tools you connect in your workspace."; font.pixelSize: 13; color: Theme.secondary; Layout.fillWidth: true; wrapMode: Text.Wrap }
                    }
                }
                Panel {
                    visible: root.controller.detailTab === "Integrations" || root.controller.detailTab === "Reviews" || root.controller.detailTab === "Support"
                    Layout.fillWidth: true; implicitHeight: informationColumn.implicitHeight + 48
                    ColumnLayout {
                        id: informationColumn; anchors.fill: parent; anchors.margins: 24; spacing: 16
                        MokaidIcon { name: root.controller.detailTab === "Integrations" ? "integrations" : root.controller.detailTab === "Reviews" ? "star" : "headphones"; color: Theme.primary; size: 30 }
                        MokaidLabel { text: root.controller.detailTab === "Integrations" ? "Connect your own tools" : root.controller.detailTab === "Reviews" ? "No reviews available" : "About your purchase"; font.pixelSize: 19; font.weight: Font.DemiBold }
                        MokaidLabel { text: root.controller.detailTab === "Integrations" ? "Connections are private to each workspace. The creator’s accounts and credentials are never transferred. Connect your tools in Integrations after adding the agent." : root.controller.detailTab === "Reviews" ? "Reviews and ratings have not been published for this listing. Explore the agent’s skills and included knowledge before choosing." : root.terms + " Payments are handled securely by Stripe. Manage your agent from Agents after your payment is confirmed."; color: Theme.secondary; font.pixelSize: 13; Layout.fillWidth: true; Layout.maximumWidth: 760; wrapMode: Text.Wrap; lineHeight: 1.3 }
                        MokaidLabel { visible: root.controller.detailTab === "Support"; text: "Included: skills and linked knowledge. Private chats, tasks, Drive files and connected accounts stay with the creator."; color: Theme.muted; font.pixelSize: 12; Layout.fillWidth: true; wrapMode: Text.Wrap }
                    }
                }
                Panel {
                    Layout.fillWidth: true; implicitHeight: 78
                    RowLayout {
                        anchors.fill: parent; anchors.margins: 18; spacing: 20
                        Repeater {
                            model: [
                                {icon:"star",value:"Level " + (root.listing.agent_level || root.agent.level || 1),label:"Training level"},
                                {icon:"knowledge",value:String(root.listing.knowledge_item_count || 0),label:"Knowledge items"},
                                {icon:"bolt",value:String(root.skills.length),label:"Listed skills"},
                                {icon:"shield",value:root.listing.mode === "sale" ? "Own copy" : "Rental",label:"Access type"}
                            ]
                            RowLayout {
                                required property var modelData; Layout.fillWidth: true; spacing: 10
                                MokaidIcon { name: modelData.icon; size: 22; color: "#b298e9" }
                                ColumnLayout { spacing: 3; MokaidLabel { text: modelData.value; font.pixelSize: 15; font.weight: Font.Bold }
MokaidLabel { text: modelData.label; font.pixelSize: 10; color: Theme.muted } }
                            }
                        }
                    }
                }
            }
            ColumnLayout {
                visible: root.checkout
                Layout.fillWidth: true; spacing: 8
                MokaidLabel { text: "Complete your purchase"; font.pixelSize: 26; font.weight: Font.Bold }
                MokaidLabel { text: "Review your plan and start using " + root.agentName + "."; color: Theme.secondary; font.pixelSize: 13 }
            }
            RowLayout {
                id: checkoutColumns
                visible: root.checkout
                Layout.fillWidth: true; Layout.minimumWidth: 0; spacing: 24
                ColumnLayout {
                    Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.minimumWidth: 0; Layout.alignment: Qt.AlignTop; spacing: 16
                    Panel {
                        Layout.fillWidth: true; implicitHeight: 96
                        RowLayout {
                            anchors.fill: parent; anchors.margins: 18; spacing: 16
                            WorkforcePortrait { agent: root.controller.faceAgent(root.agent); size: 58 }
                            ColumnLayout { Layout.fillWidth: true; spacing: 5; MokaidLabel { text: root.agentName; font.pixelSize: 16; font.weight: Font.Bold; Layout.fillWidth: true; elide: Text.ElideRight }
MokaidLabel { text: root.controller.roleTitle(root.agent); color: Theme.secondary; font.pixelSize: 12 } }
                        }
                    }
                    Panel {
                        Layout.fillWidth: true; implicitHeight: planColumn.implicitHeight + 36
                        color: "#201530"; border.color: "#9b5df3"
                        ColumnLayout {
                            id: planColumn; anchors.fill: parent; anchors.margins: 18; spacing: 10
                            RowLayout { Layout.fillWidth: true; MokaidIcon { name: "tasks"; color: "#b87dff"; size: 20 }
MokaidLabel { text: root.listing.mode === "sale" ? "One-time purchase" : root.listing.rent_billing === "subscription" ? "Monthly rental" : (root.listing.fixed_days || 30) + "-day rental"; font.pixelSize: 14; font.weight: Font.DemiBold } }
                            MokaidLabel { text: root.controller.priceLabel(root.listing); font.pixelSize: 22; font.weight: Font.Bold }
                            MokaidLabel { text: root.terms; Layout.fillWidth: true; color: Theme.secondary; font.pixelSize: 12; wrapMode: Text.Wrap; lineHeight: 1.25 }
                        }
                    }
                    Benefit { text: "Full access to the agent’s skills"; Layout.fillWidth: true }
                    Benefit { text: "Linked knowledge included"; Layout.fillWidth: true }
                    Benefit { text: "Secure payment through Stripe"; Layout.fillWidth: true }
                    Benefit { text: root.listing.mode === "sale" ? "Agent added to your workspace after payment" : root.listing.rent_billing === "subscription" ? "Cancel your subscription anytime" : "Clear rental end date"; Layout.fillWidth: true }
                }
                Panel {
                    Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.minimumWidth: 0; Layout.alignment: Qt.AlignTop; implicitHeight: summary.implicitHeight + 40
                    ColumnLayout {
                        id: summary; anchors.fill: parent; anchors.margins: 20; spacing: 20
                        MokaidLabel { text: "Order summary"; font.pixelSize: 17; font.weight: Font.Bold }
                        RowLayout { Layout.fillWidth: true; MokaidLabel { text: root.agentName; color: Theme.secondary; font.pixelSize: 13; Layout.fillWidth: true; elide: Text.ElideRight }
MokaidLabel { text: root.controller.money(root.listing.price_cents, root.listing.currency); font.pixelSize: 13 } }
                        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.divider }
                        RowLayout { Layout.fillWidth: true; MokaidLabel { text: "Total (" + String(root.listing.currency || "usd").toUpperCase() + ")"; font.pixelSize: 14; font.weight: Font.DemiBold; Layout.fillWidth: true }
MokaidLabel { text: root.controller.money(root.listing.price_cents, root.listing.currency); font.pixelSize: 18; font.weight: Font.Bold } }
                        MokaidLabel { text: "The platform fee is included in the price."; color: Theme.muted; font.pixelSize: 11; Layout.fillWidth: true; wrapMode: Text.Wrap }
                        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.divider }
                        MokaidLabel { text: "Payment method"; font.pixelSize: 13; font.weight: Font.DemiBold }
                        RowLayout { spacing: 10; MokaidIcon { name: "billing"; color: Theme.primary; size: 23 }
MokaidLabel { text: "Card & available payment methods"; color: Theme.secondary; font.pixelSize: 12; Layout.fillWidth: true; wrapMode: Text.Wrap } }
                        MokaidLabel { text: "Choose your payment method in the secure Stripe checkout that opens in your browser."; color: Theme.secondary; font.pixelSize: 12; wrapMode: Text.Wrap; Layout.fillWidth: true }
                        MokaidButton {
                            objectName: "marketplaceCheckoutConfirm"; Layout.fillWidth: true
                            text: features.busy ? "Please wait…" : root.controller.checkoutSubmitted && !features.error ? "Checkout opened in browser" : "Continue to secure checkout"
                            highlighted: true; enabled: !features.busy && !features.offline && (!root.controller.checkoutSubmitted || !!features.error)
                            onClicked: root.controller.openCheckout(root.listing.id)
                        }
                        MokaidButton { objectName: "marketplacePurchaseRefresh"; visible: root.controller.checkoutSubmitted; text: "Check payment status"; Layout.fillWidth: true; enabled: !features.busy && !features.offline; onClicked: root.controller.refreshPurchase() }
                        MokaidLabel { visible: !!root.controller.purchaseNote; text: root.controller.purchaseNote; color: Theme.secondary; font.pixelSize: 12; Layout.fillWidth: true; wrapMode: Text.Wrap }
                        RowLayout { Layout.alignment: Qt.AlignHCenter; spacing: 6; MokaidIcon { name: "lock"; size: 12; color: Theme.muted }
MokaidLabel { text: "Secure payment powered by Stripe"; color: Theme.muted; font.pixelSize: 10 } }
                    }
                }
            }
            ColumnLayout {
                visible: root.success
                Layout.fillWidth: true; Layout.topMargin: 36; spacing: 22
                Item {
                    Layout.fillWidth: true; implicitHeight: 155
                    Rectangle { anchors.centerIn: parent; width: 102; height: 102; radius: 51; color: "#101322"; border.width: 2; border.color: "#9263f2"; MokaidIcon { anchors.centerIn: parent; name: "check"; size: 48; color: "#19e4ba" } }
                    Repeater {
                        model: 10
                        Rectangle { required property int index; x: parent.width / 2 + Math.cos(index * .7) * (140 + (index % 3) * 25); y: 68 + Math.sin(index * .7) * 60; width: index % 2 ? 5 : 7; height: width; radius: index % 2 ? 1 : 4; rotation: 45; color: ["#aa52ff", "#697ef2", "#28d8cc"][index % 3] }
                    }
                }
                MokaidLabel { text: "Agent purchased successfully!"; font.pixelSize: 25; font.weight: Font.Bold; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                MokaidLabel { text: root.agentName + " is now available in your agents."; font.pixelSize: 14; color: Theme.secondary; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
                MokaidButton { text: "Go to my agents"; highlighted: true; Layout.preferredWidth: 340; Layout.alignment: Qt.AlignHCenter; Layout.topMargin: 12; onClicked: features.navigate("agents") }
                MokaidButton { text: "View marketplace"; Layout.preferredWidth: 340; Layout.alignment: Qt.AlignHCenter; onClicked: root.controller.showBrowse("discover") }
                Panel {
                    Layout.fillWidth: true; Layout.maximumWidth: 740; Layout.alignment: Qt.AlignHCenter; Layout.topMargin: 16; implicitHeight: 104
                    RowLayout {
                        anchors.fill: parent; anchors.margins: 20; spacing: 18
                        WorkforcePortrait { agent: root.controller.faceAgent(root.agent); size: 64 }
                        ColumnLayout { Layout.fillWidth: true; spacing: 5; MokaidLabel { text: root.agentName; font.pixelSize: 16; font.weight: Font.Bold }
MokaidLabel { text: root.controller.roleTitle(root.agent); color: Theme.secondary; font.pixelSize: 12 } }
                        MokaidLabel { text: "Active"; color: Theme.success; padding: 7; font.pixelSize: 11; background: Rectangle { color: "#0f2b25"; radius: 5; border.color: "#26816b" } }
                        MokaidButton { text: "Start using"; iconName: "arrow-right"; onClicked: features.openRecord("agent-detail", root.controller.purchasedOrder.cloned_agent_id) }
                    }
                }
            }
        }
    }
}
