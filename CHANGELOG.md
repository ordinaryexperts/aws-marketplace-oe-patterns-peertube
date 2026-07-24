# Unreleased

# 3.1.1

* Fix a CloudFormation dependency-ordering bug where the ASG could launch before the ElastiCache Redis cluster's endpoint attributes (`RedisEndpoint.Address`/`.Port`) were resolved, leaving newly-launched instances with an empty `redis:` section in `config/production.yaml`. PeerTube would then crash-loop on startup (ioredis `ERR_MISSING_ARGS`), which surfaced as a 502 Bad Gateway from the ALB since nginx's `/elb-check` health check doesn't depend on the PeerTube app being up. The ASG now has an explicit CDK dependency on the Redis cluster, mirroring the existing dependency on the database.
* No install-script changes in this release; AMI rebuilt from the same PeerTube v8.2.3 install script as 3.1.0 (AWS Marketplace requires a distinct AMI ID per submitted version).

# 3.1.0

* Upgrade to PeerTube v8.2.3 (from v8.1.5)
  * Security: v8.1.6 fixed a SQL injection vulnerability that was actively exploited in the wild since 2026-05-18 (attackers used it to mint root tokens and install a malicious plugin). Deployments on v8.1.5 or earlier should upgrade promptly.
  * v8.2.2/v8.2.3 include further security fixes: ActivityPub actor/host validation on `Update` activities, HLS object-storage path validation, P2P segment validator hardening, OAuth token redaction in debug logs
  * No `config/production.yaml` schema changes in the sections this pattern patches (object_storage, database, redis, smtp, signup, admin, transcoding); no manual migration steps required
* Bump AMI parameter to `AsgAmiIdv310`

# 3.0.0

* Upgrade to PeerTube v8.1.5
  * Upstream replaced `yarn` with `pnpm`; install script now uses `npm run install-node-dependencies`
  * Manual post-upgrade migration required for existing deployments - see https://github.com/Chocobozzz/PeerTube/releases/tag/v8.0.0 (run `peertube-8.0.js` after the v8 database migration completes)
  * New `object_storage.captions` bucket configuration wired to the same S3 bucket + CloudFront distribution
* Upgrade base AMI from Ubuntu 22.04 to Ubuntu 24.04 (Noble Numbat)
* Upgrade to OE devenv version 2.8.3
* Upgrade to OE Common Constructs version 4.5.1
  * Aurora PostgreSQL upgraded 15.4 -> 15.13 (causes brief downtime on stack update)
  * ElastiCache Redis upgraded 6.2 -> 7.0
* Upgrade to aws-cdk-lib 2.225.0
* Introduce versioned AMI parameter (`AsgAmiIdv300`) so CloudFormation treats each release's AMI swap as a parameter change

# 2.1.0

* Upgrade to PeerTube v7.0.1
* Upgrade to Node.js v22.x
* Upgrade to OE Common Constructs version 4.1.9
* Downgrade to Ubuntu system FFMPEG version 4.4.2

# 2.0.0

* Upgrade to PeerTube version 6.1.0
* Upgrade to FFMPEG version 6.0.1
* Upgrade to OE Common Constructs version 3.20.0
  * Upgrade to Postgres Aurora 15.4
* Upgrade to OE devenv version 2.5.1
  * Update pricing

# 1.1.0

* Fix issue with ALB when creating VPC
* Upgrade to PeerTube version 5.2.0

# 1.0.0

* Initial development
* Graviton support
* CloudFront support
