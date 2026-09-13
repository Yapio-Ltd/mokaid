# Non-secret, reviewed rollout state. Keep enabled after ACM provisioning so a
# future production plan cannot accidentally remove its managed certificate.
desktop_downloads_enabled            = true
desktop_downloads_external_dns_ready = true

# Explicitly approved stable macOS role only; independent of CloudFront readiness.
# A reviewed targeted plan must be applied separately. No release is activated.
desktop_stable_signing_enabled = true
