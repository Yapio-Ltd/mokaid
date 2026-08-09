"""Mailbox synchronization and AI analysis.

Fetches new email from Gmail (REST), Microsoft Graph (delta queries) or IMAP,
normalizes messages into a common shape, scores them with the LLM against the
workspace's natural-language rules, and reports everything back to Phoenix.
"""
