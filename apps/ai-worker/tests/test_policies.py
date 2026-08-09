from app.policies.approval import ApprovalPolicy, requires_approval, risk_for_tool
from app.schemas import RiskLevel


def test_read_only_tools_do_not_require_approval():
    assert not requires_approval("search_knowledge")
    assert not requires_approval("web_search")
    assert risk_for_tool("web_search") == RiskLevel.LOW
    assert not requires_approval("summarize")
    assert not requires_approval("traverse_knowledge")
    assert not requires_approval("knowledge_path")
    assert not requires_approval("explain_concept")
    assert not requires_approval("save_knowledge_outcome")


def test_external_side_effects_require_approval():
    assert requires_approval("send_email")
    assert requires_approval("post_social")
    assert requires_approval("make_purchase")


def test_site_delivery_choice_always_gated():
    assert risk_for_tool("choose_site_delivery") == RiskLevel.HIGH
    assert requires_approval("choose_site_delivery")


def test_unknown_tools_default_to_high_risk():
    assert risk_for_tool("mystery_tool") == RiskLevel.HIGH
    assert requires_approval("mystery_tool")


def test_policy_default_matches_balanced_mode():
    policy = ApprovalPolicy(None)
    assert policy.decision("web_search") == "auto"
    assert policy.decision("draft_document") == "auto"
    assert policy.decision("send_email") == "ask"


def test_policy_supervised_gates_medium_risk():
    policy = ApprovalPolicy({"mode": "supervised"})
    assert policy.decision("draft_document") == "ask"
    assert policy.decision("web_search") == "auto"


def test_policy_autonomous_only_gates_critical():
    policy = ApprovalPolicy({"mode": "autonomous"})
    assert policy.decision("send_email") == "auto"
    assert policy.decision("make_purchase") == "ask"


def test_policy_allow_rule_preapproves_gated_tool():
    policy = ApprovalPolicy(
        {"mode": "balanced", "rules": [{"tool_pattern": "send_email", "behavior": "allow"}]}
    )
    assert policy.decision("send_email") == "allow"
    assert policy.decision("post_social") == "ask"


def test_policy_deny_rule_beats_allow_and_mode():
    policy = ApprovalPolicy(
        {
            "mode": "autonomous",
            "rules": [
                {"tool_pattern": "post_social", "behavior": "deny"},
                {"tool_pattern": "post_social", "behavior": "allow"},
            ],
        }
    )
    assert policy.decision("post_social") == "deny"


def test_policy_wildcard_matches_mcp_tools():
    policy = ApprovalPolicy(
        {"mode": "balanced", "rules": [{"tool_pattern": "mcp:github:*", "behavior": "allow"}]}
    )
    assert policy.decision("mcp:github:create_issue") == "allow"
    assert policy.decision("mcp:slack:post_message") == "ask"


def test_policy_site_delivery_choice_always_asks():
    policy = ApprovalPolicy(
        {
            "mode": "autonomous",
            "rules": [{"tool_pattern": "*", "behavior": "allow"}],
        }
    )
    assert policy.decision("choose_site_delivery") == "ask"


def test_policy_invalid_mode_falls_back_to_balanced():
    policy = ApprovalPolicy({"mode": "yolo"})
    assert policy.mode == "balanced"
    assert policy.decision("send_email") == "ask"
