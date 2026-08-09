"""Tests for the mail sync pipeline: normalization and LLM analysis plumbing."""

from email.message import EmailMessage

from app.mail import analyze, normalize


class TestHtmlToText:
    def test_strips_tags_and_scripts(self):
        html = "<html><script>alert(1)</script><p>Hello <b>world</b></p></html>"
        text = normalize.html_to_text(html)
        assert "Hello" in text and "world" in text
        assert "alert" not in text
        assert "<" not in text

    def test_decodes_entities(self):
        assert normalize.html_to_text("a &amp; b &lt;ok&gt;") == "a & b <ok>"

    def test_handles_none(self):
        assert normalize.html_to_text("") == ""


class TestAddresses:
    def test_parse_address(self):
        name, email = normalize.parse_address("Alice Smith <Alice@Example.COM>")
        assert name == "Alice Smith"
        assert email == "alice@example.com"

    def test_parse_address_list(self):
        emails = normalize.parse_address_list("a@x.com, Bob <B@Y.com>")
        assert emails == ["a@x.com", "b@y.com"]

    def test_empty(self):
        assert normalize.parse_address(None) == ("", "")
        assert normalize.parse_address_list(None) == []


class TestMimeToNormalized:
    def _build_message(self) -> EmailMessage:
        msg = EmailMessage()
        msg["From"] = "Alice <alice@example.com>"
        msg["To"] = "bob@example.com"
        msg["Subject"] = "Invoice #42"
        msg["Date"] = "Mon, 03 Aug 2026 10:00:00 +0000"
        msg["Message-ID"] = "<thread-1@example.com>"
        msg.set_content("Please find the invoice attached.")
        msg.add_attachment(b"%PDF-", maintype="application", subtype="pdf", filename="invoice.pdf")
        return msg

    def test_full_normalization(self):
        normalized = normalize.mime_to_normalized(self._build_message(), "uid-1")

        assert normalized["provider_message_id"] == "uid-1"
        assert normalized["from_email"] == "alice@example.com"
        assert normalized["from_name"] == "Alice"
        assert normalized["to_emails"] == ["bob@example.com"]
        assert normalized["subject"] == "Invoice #42"
        assert "invoice" in normalized["body_text"].lower()
        assert normalized["has_attachments"] is True
        assert normalized["received_at"].startswith("2026-08-03")

    def test_html_only_body(self):
        msg = EmailMessage()
        msg["From"] = "x@y.com"
        msg.set_content("<p>Rich <b>content</b></p>", subtype="html")

        normalized = normalize.mime_to_normalized(msg, "uid-2")
        assert "Rich" in normalized["body_text"]
        assert "<p>" not in normalized["body_text"]

    def test_encoded_subject(self):
        msg = EmailMessage()
        msg["Subject"] = "=?utf-8?B?RmFjdHVyZSDDoCBwYXllcg==?="
        msg.set_content("body")

        normalized = normalize.mime_to_normalized(msg, "uid-3")
        assert normalized["subject"] == "Facture à payer"


class TestAnalyzeApply:
    def test_clamps_importance_and_filters_rules(self):
        message: dict = {}
        analyze._apply(
            message,
            {
                "importance": 250,
                "category": "invoice",
                "summary": "Pay invoice #42 by Friday.",
                "matched_rule_ids": ["rule-1", "rule-unknown"],
            },
            valid_rule_ids={"rule-1"},
        )

        assert message["ai_importance"] == 100
        assert message["ai_category"] == "invoice"
        assert message["ai_summary"] == "Pay invoice #42 by Friday."
        assert message["matched_rule_ids"] == ["rule-1"]
        assert message["analyzed_at"]

    def test_ignores_invalid_values(self):
        message: dict = {}
        analyze._apply(
            message,
            {"importance": "high", "category": "nonsense", "summary": "", "matched_rule_ids": "x"},
            valid_rule_ids=set(),
        )

        assert "ai_importance" not in message
        assert "ai_category" not in message
        assert "ai_summary" not in message
        assert "matched_rule_ids" not in message


class TestSnippet:
    def test_collapses_whitespace(self):
        assert normalize.snippet_of("a\n\n  b\tc") == "a b c"

    def test_limits_length(self):
        assert len(normalize.snippet_of("x" * 1000)) == 300
