# Unreleased

# 3.0.0

* Upgrade to PeerTube v8.1.5
  * Upstream replaced `yarn` with `pnpm`; install script now uses `npm run install-node-dependencies`
  * Manual post-upgrade migration required for existing deployments — see https://github.com/Chocobozzz/PeerTube/releases/tag/v8.0.0 (run `peertube-8.0.js` after the v8 database migration completes)
  * New `object_storage.captions` bucket configuration wired to the same S3 bucket + CloudFront distribution
* Upgrade base AMI from Ubuntu 22.04 to Ubuntu 24.04 (Noble Numbat)
* Upgrade to OE devenv version 2.8.3
* Upgrade to OE Common Constructs version 4.5.1
  * Aurora PostgreSQL upgraded 15.4 → 15.13 (causes brief downtime on stack update)
  * ElastiCache Redis upgraded 6.2 → 7.0
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
