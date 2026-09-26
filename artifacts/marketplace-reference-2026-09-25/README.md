# Native Marketplace reference captures

Design reference: the user-supplied `ChatGPT Image Sep 25, 2026, 10_54_54 AM.png`. The implementation inherits the native Qt Quick visual system documented in [apps/desktop/DESIGN.md](../../apps/desktop/DESIGN.md).

These 14 PNGs show the Marketplace content area rendered by isolated native QML fixtures in [native_pages_qml_tests.cpp](../../apps/desktop/application/features/tests/native_pages_qml_tests.cpp), with synthetic records served by a local test API. They exclude the application sidebar, global header, and operating-system chrome. The 1140 captures use a 1140 × 760 content viewport; the 760 captures use 760 × 700.

Checkout and success images demonstrate UI states and the persisted-order confirmation contract under fixture responses. No real payment was charged; these captures do not validate a live payment provider or a production clone. In the application, success requires the matching persisted order to be `fulfilled` and to contain a `cloned_agent_id`.

## Implementation map

| File | Responsibility |
| --- | --- |
| `apps/desktop/presentation/qml/MarketplacePage.qml` | Screen coordination, real listing records, filters, workspace-local favorite IDs, checkout and purchase confirmation. |
| `apps/desktop/presentation/qml/MarketplaceDiscover.qml` | Discovery banner, category directory, search results and browsing controls. |
| `apps/desktop/presentation/qml/MarketplaceCard.qml` | Listing card with the actual agent identity, offer terms and favorite action. |
| `apps/desktop/presentation/qml/MarketplaceDetail.qml` | Agent details, checkout summary, payment status and confirmed success. |
| `apps/desktop/presentation/qml/MarketplaceSeller.qml` | Seller listings and the validated publication wizard. |
| `apps/desktop/presentation/qml/MarketplaceEarnings.qml` | Recorded earnings, dated revenue chart, category totals and order rows. |
| `apps/desktop/application/features/feature_controller.cpp` | Endpoint-backed actions and action results. |
| `apps/desktop/presentation/assets/marketplace-hero.provenance.json` | Hero source reference, exact generation prompt and image-generation provenance. |

## Captures

| Screen | Wide | Compact |
| --- | --- | --- |
| Discovery | [1140](marketplace-discover-1140.png) | — |
| Categories | [1140](marketplace-categories-1140.png) | — |
| Search and filters | [1140](marketplace-search-1140.png) | — |
| Agent details | [1140](marketplace-detail-1140.png) | [760](marketplace-detail-760.png) |
| Checkout | [1140](marketplace-checkout-1140.png) | [760](marketplace-checkout-760.png) |
| Confirmed success | [1140](marketplace-success-1140.png) | [760](marketplace-success-760.png) |
| Seller listings | [1140](marketplace-listings-1140.png) | — |
| Create listing | [1140](marketplace-publish-1140.png) | [760](marketplace-publish-760.png) |
| Earnings | [1140](marketplace-earnings-1140.png) | [760](marketplace-earnings-760.png) |
