#!/usr/bin/env bash
# Declare Stalwart's configuration: blob store, mail domain, the administrator,
# the certsync account, and the SMTP policy below. Rendered from the env files
# and applied with stalwart-cli, so no setup happens in the web UI.
#
# First run: right after the first `up` with the setup overlay, which starts
# Stalwart in recovery mode as the administrator named below. A plain
# `docker compose up -d` afterwards restarts it normally; that first normal
# start generates the domain's DKIM keys.
#
#   ENV_FILE=.env ./scripts/stalwart-apply.sh    # local stack
#   ./scripts/stalwart-apply.sh                  # production (after source scripts/prod.env)
#
# Idempotent: re-running updates the same objects, and resets the two account
# passwords to the ones in the env files. A running server picks up changes at
# its next restart. STALWART_ADMIN_PASSWORD comes from the setup file, or from
# the environment once that file is gone.
set -euo pipefail
cd "$(dirname "$0")/.."
ENV_FILE="${ENV_FILE:-.env.production}"
[[ -f "$ENV_FILE" ]] || { echo "$ENV_FILE not found — run: source scripts/prod.env" >&2; exit 1; }
set -a; . "$ENV_FILE"; [[ -f "$ENV_FILE.setup" ]] && . "$ENV_FILE.setup"; set +a

for v in MAIL_DOMAIN MX_DOMAIN STALWART_CLI_IMAGE STALWART_ADMIN_PASSWORD STALWART_CERTSYNC_PASSWORD; do
  [[ -n "${!v:-}" && "${!v}" != "CHANGEME" ]] || { echo "$v is not set" >&2; exit 1; }
done

# Unknown recipients at MAIL_DOMAIN: the domain allows relaying, so the user's
# client can send to MAIL_DOMAIN mailboxes that are not on this server. That flag
# also makes port 25 accept any address there from anyone; this Sieve script
# rejects them for unauthenticated sessions.
reject_unknown='require "reject";
reject "550 5.1.1 Mailbox does not exist.";'
rcpt_guard="is_empty(authenticated_as) && rcpt_domain == '$MAIL_DOMAIN' && !is_local_address(rcpt)"

jq -nc --arg dom "$MAIL_DOMAIN" --arg host "$MX_DOMAIN" \
  --arg adminpw "$STALWART_ADMIN_PASSWORD" --arg certpw "$STALWART_CERTSYNC_PASSWORD" \
  --arg sieve "$reject_unknown" --arg guard "$rcpt_guard" --arg script "'reject-unknown'" '
  {"@type":"update","object":"BlobStore","value":{"@type":"FileSystem","path":"/var/lib/stalwart/blobs","depth":3}},
  {"@type":"upsert","object":"Domain","matchOn":["name"],"value":{"dom":{"name":$dom,
    "certificateManagement":{"@type":"Manual"},"dnsManagement":{"@type":"Manual"},
    "dkimManagement":{"@type":"Automatic","algorithms":{"Dkim1Ed25519Sha256":true,"Dkim1RsaSha256":true}},
    "allowRelaying":true}}},
  {"@type":"upsert","object":"Account","matchOn":["name"],"value":{"adm":{"@type":"User","name":"admin","domainId":"#dom",
    "roles":{"@type":"Admin"},"credentials":{"0":{"@type":"Password","secret":$adminpw}}}}},
  # Scoped to what stalwart-cert-sync.sh needs. Permissions instead of a custom
  # Role: Stalwart seeds its default roles only while no Role exists.
  {"@type":"upsert","object":"Account","matchOn":["name"],"value":{"cs":{"@type":"User","name":"certsync","domainId":"#dom",
    "roles":{"@type":"User"},
    "permissions":{"@type":"Replace","enabledPermissions":{"authenticate":true,
      "sysCertificateGet":true,"sysCertificateQuery":true,"sysCertificateCreate":true,"sysCertificateUpdate":true,
      "sysActionCreate":true,"actionReloadTlsCertificates":true}},
    "credentials":{"0":{"@type":"Password","secret":$certpw}}}}},
  # The default tracer writes to /var/log/stalwart, which the read-only root
  # filesystem refuses; stdout reaches `docker logs`. Tracers have no name, so
  # they match by value, which needs every field spelled out.
  {"@type":"reconcile","object":"Tracer","matchOn":"*","value":{"out":{"@type":"Stdout",
    "multiline":false,"lossy":false,"ansi":false,"buffered":true,"enable":true,"events":{},"eventsPolicy":"exclude","level":"info"}}},
  {"@type":"update","object":"SystemSettings","value":{"defaultDomainId":"#dom","defaultHostname":$host}},
  # Mail forwarded by Google fails the original sender SPF check; its ARC seal
  # lets the spam filter see the result Google recorded.
  {"@type":"update","object":"SenderAuth","value":{"arcVerify":{"match":{"0":{"if":"local_port == 25","then":"relaxed"}},"else":"disable"}}},
  {"@type":"upsert","object":"SieveSystemScript","matchOn":["name"],"value":{"rj":{"name":"reject-unknown","contents":$sieve,"isActive":true}}},
  {"@type":"update","object":"MtaStageRcpt","value":{"script":{"match":{"0":{"if":$guard,"then":$script}},"else":"false"}}}
' | STALWART_PASSWORD="$STALWART_ADMIN_PASSWORD" docker run --rm -i \
      --network private-cloud_proxy -e STALWART_USER=admin -e STALWART_PASSWORD \
      "$STALWART_CLI_IMAGE" apply --stdin --url http://stalwart:8080
