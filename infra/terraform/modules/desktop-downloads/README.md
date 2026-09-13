# Native desktop distribution

Private S3 origin, CloudFront OAC, HTTPS-only download host, short-lived stable/beta
feeds, immutable versioned installers, protected-environment GitHub OIDC roles.
The module publishes **no installer or feed**. Missing files return a truthful 404.

Inputs are declared and validated in `main.tf`. Required values are an exact
bucket name, validated **us-east-1** ACM certificate ARN, existing GitHub OIDC
provider ARN and signing-secret ARN map (an empty map intentionally creates no
signing roles). `route53_zone_id = null` leaves DNS under external ownership.
No private key, token, certificate password or Secrets Manager value is an input.

The production root's `desktop_downloads.tf` reuses the bootstrap OIDC provider.
The variable defaults are disabled, but the reviewed `desktop.auto.tfvars` now
persists `desktop_downloads_enabled=true` after the initial ACM request. This file
contains only two non-secret boolean switches and has an explicit Git ignore
exception. Do not remove it after provisioning. `prevent_destroy` also protects
the managed certificate against an accidental disabled count. Existing
backend/API/web services are not replaced by this module.
For an externally hosted DNS zone:

1. Review a plan with `desktop_downloads_enabled=true` and
   `desktop_downloads_external_dns_ready=false`. This requests only the ACM
   certificate; it does not wait for external DNS or create the distribution.
2. After applying that reviewed plan, add the CNAME values from
   `desktop_downloads_certificate_dns_records` to the authoritative DNS provider.
   Keep these records for automatic certificate renewal.
3. Set `desktop_downloads_external_dns_ready=true`. Review another plan. ACM must
   actually validate before CloudFront can be created; the boolean does not bypass
   AWS certificate verification. Add `downloads` as a DNS-only CNAME to the emitted
   `desktop_downloads.external_dns_cname` (do not add another CDN/proxy).
4. Configure GitHub environment variables from the non-secret Terraform outputs
   and the reviewed signing setup described in `apps/desktop/docs/releases.md`.

If a public Route53 zone already exists, supply its exact ID; Terraform creates
only the relevant DNS records, never a new hosted zone or nameserver delegation.
An existing validated certificate can also be supplied instead of requesting one.

The signing role can read only the exact channel-specific secret ARNs and optional
KMS keys. The publisher cannot read secrets or delete objects. Bucket policy
requires conditional creation for `releases/*`; artifact paths cannot be silently
replaced. Feed recovery uses previous S3 object versions via an independently
reviewed operator role, not the publisher's permissions. Public promotion is also
blocked by the version-bound acceptance evidence and protected GitHub environments.

Validation, without AWS credentials or infrastructure creation:

```sh
terraform init -backend=false
terraform validate
tflint
terraform test
```

The tests use Terraform's mocked AWS provider and cover external/Route53 DNS,
origin privacy, versioning, channel isolation, missing signing configuration and
invalid wildcard-secret/certificate inputs. GitHub Actions repeats these checks
and validates the production root with an isolated `TF_DATA_DIR`, backend disabled.
Cloud provisioning remains a separately reviewed operation; validation CI has no
OIDC permission and no `apply` step.
