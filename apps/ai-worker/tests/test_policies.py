from app.policies.approval import requires_approval, risk_for_tool
from app.schemas import RiskLevel


def test_read_only_tools_do_not_require_approval():
    assert not requires_approval("search_knowledge")
    assert not requires_approval("web_search")
    assert risk_for_tool("web_search") == RiskLevel.LOW
    assert not requires_approval("summarize")


def test_external_side_effects_require_approval():
    assert requires_approval("send_email")
    assert requires_approval("post_social")
    assert requires_approval("make_purchase")


def test_unknown_tools_default_to_high_risk():
    assert risk_for_tool("mystery_tool") == RiskLevel.HIGH
    assert requires_approval("mystery_tool")
