# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repo produces the **Ordinary Experts PeerTube Pattern**, an AWS Marketplace product consisting of:

1. A custom Ubuntu 22.04 arm64 AMI with PeerTube pre-installed (built with Packer)
2. A CloudFormation template (synthesized from AWS CDK / Python) that deploys a production-ready PeerTube stack: ASG + ALB + Aurora Postgres + ElastiCache Redis + S3 + CloudFront + SES + Route53

End-users launch the published template from AWS Marketplace; they do not run the CDK themselves. The CDK synth output (`template.yaml`) and the AMI are the shippable artifacts.

## How the Build System Works

Nearly every developer command runs inside the `ordinaryexperts/aws-marketplace-patterns-devenv` Docker image defined by the root `Dockerfile` + `docker-compose.yml`. Make targets are the canonical entry point and wrap `docker compose run ... devenv <cmd>`.

Make targets come from two places:
- `Makefile` (local) — the per-project `deploy` target with hardcoded dev-account CFN parameters, and `update-common`
- `common.mk` (generated, gitignored) — shared targets (`build`, `synth`, `test-main`, `clean-*`, `ami-ec2-build`, `plf`, etc.), fetched from `aws-marketplace-utilities` at a pinned version

**`common.mk` is managed in the [aws-marketplace-utilities](https://github.com/ordinaryexperts/aws-marketplace-utilities) repo — do not add targets to it here. Local-only targets go in `Makefile`.**

Bootstrap a fresh checkout with `make update-common && make build`.

## Common Commands

| Command | Purpose |
|---|---|
| `make update-common` | Fetch pinned `common.mk` from aws-marketplace-utilities |
| `make build` | Build the devenv Docker image (needed before most other targets) |
| `make synth` | Run `cdk synth` inside devenv, emitting the CFN template |
| `make diff` | `cdk diff` against currently-deployed stack |
| `make deploy` | Deploy to the dev account with the hardcoded parameters in `Makefile` (personalized by `$USER`) |
| `make destroy` | Tear down the deployed stack |
| `make test-main` | Run the `main-test` taskcat scenario (full stack deploy + validate in us-east-1) — what CI runs |
| `make ami-ec2-build` | Build a new AMI via Packer on an EC2 builder |
| `make bash` | Open a shell inside the devenv container |
| `make clean-snapshots-tcat` / `make clean-logs-tcat` | Clean up taskcat leftovers (CI runs these post-test) |
| `make plf` / `make gen-plf` | Generate/update the Marketplace Product Load Form from `plf_config.yaml` |

Run a single CDK unit test inside devenv:
```
make bash
cd cdk && pytest tests/unit/test_peertube_stack.py::test_sqs_queue_created
```

CI (`.github/workflows/main.yml`) runs on push/PR to `develop` and Mondays: `make update-common && make build && make test-main`.

## Architecture

### CDK stack (`cdk/peertube/peertube_stack.py`)

`PeertubeStack` is a thin assembly of reusable constructs from `oe-patterns-cdk-common` (pinned in `cdk/requirements.txt`). That shared library owns almost all infrastructure — VPC, ALB, ASG, Aurora Postgres, ElastiCache Redis, S3 assets bucket, SES, Route53, DB secret, subnet-to-AZ lookup, parameter-group metadata. **When you see CloudFormation parameters like `AlbCertificateArn`, `DnsHostname`, `AsgInstanceType`, etc., they are defined in the shared constructs, not here.** To understand their behavior, read the `oe-patterns-cdk-common` source at the version pinned in `requirements.txt`.

What this repo adds on top of the shared constructs:
- `AdminEmail` parameter (PeerTube admin bootstrap)
- `CloudFrontPriceClass` parameter + `aws_cloudfront.CfnDistribution` fronting the S3 assets bucket for video/streaming delivery
- Wiring the ASG to an `AllowUpdateInstanceSecret` IAM policy so `check-secrets.py` (see below) can write generated secrets back to Secrets Manager
- `singleton=True, use_data_volume=True, use_graviton=True` — scale-out is NOT supported; one instance at a time attaches the data EBS volume
- The `user_data.sh` that turns a raw instance into a running PeerTube node

`AMI_ID` is a constant at the top of `peertube_stack.py` and must be updated every time a new AMI is published (see comment showing the AMI name/version). `template_version` is auto-derived from `git describe` unless `TEMPLATE_VERSION` is set.

### AMI build (`packer/`)

`packer/ami.json` + `packer/ubuntu_2204_appinstall.sh` build the AMI on an `m7g.xlarge` arm64 instance. The install script:
1. Downloads and runs the **preinstall/postinstall scripts** from `aws-marketplace-utilities` at a pinned `SCRIPT_VERSION` (1.4.0) — these handle OS hardening, CloudWatch agent, SSM agent, common AWS marketplace requirements.
2. Installs Node.js 22.x, ffmpeg, nginx, postgresql-client, yarn.
3. Downloads PeerTube `$VERSION` (currently `v7.0.1`) from the official GitHub release, unpacks under `/var/www/peertube/versions/`, symlinks to `peertube-latest`, runs `yarn install --production`.
4. Writes a CloudWatch agent config with placeholder log-group names that `user_data.sh` later substitutes.
5. Writes `/root/check-secrets.py` — invoked at boot to generate and persist `app_key` and `root_password` into the instance's Secrets Manager secret (so they're stable across reboots but created on first run).

**To publish a new PeerTube version: bump `VERSION` in `ubuntu_2204_appinstall.sh`, run `make ami-ec2-build`, then update `AMI_ID` in `peertube_stack.py` and the product version strings in `plf_config.yaml`/`CHANGELOG.md`.**

### user_data.sh (`cdk/peertube/user_data.sh`)

CloudFormation `Fn::Sub`'ed at ASG launch. Variables come from two places:
- `${AssetsBucketName}`, `${DbSecretArn}`, `${Hostname}`, `${InstanceSecretName}` — passed explicitly via `user_data_variables` in `peertube_stack.py`
- `${DbCluster.Endpoint.Address}`, `${RedisCluster.RedisEndpoint.Address}`, `${CloudFrontDistribution.DomainName}`, `${AsgAppLogGroup}`, `${AsgSystemLogGroup}`, `${AWS::Region}`, `${AWS::StackName}`, `${VpcCidr}`, `${SesInstanceUserAccessKeySerial}`, `${AdminEmail}` — resolved by CloudFormation from other resources in the stack

The script: fetches DB + instance secrets from Secrets Manager, writes `/var/www/peertube/config/production.yaml` by patching PeerTube's example config with many line-numbered `sed` commands (fragile — line numbers must match the PeerTube release being shipped), wires up nginx (with `/elb-check` health-check endpoint and real-IP forwarding from the VPC CIDR), enables the peertube systemd unit, and finally sends a `cfn-signal` so the ASG creation policy resolves.

**The line-numbered `sed` blocks for `config/production.yaml` (streaming_playlists, web_videos, user_exports, original_video_files) break whenever PeerTube changes its example config. Verify these on every version bump.**

### Tests

- `cdk/tests/unit/` — pytest placeholder only; no real assertions.
- `test/main-test/.taskcat.yml` — the real integration test. `make test-main` uses taskcat to deploy the synthesized template into the dev AWS account, let it settle, and tear it down. This is what gates merges.

## Things That Look Weird But Are Intentional

- `template_version = "CICD"` fallback: when `git describe` fails (e.g., in a CI checkout without tags), the template still synthesizes.
- The `AsgReprovisionString` parameter in `Makefile`'s `deploy` target is a knob to force an ASG instance replacement without changing anything else.
- `SesCreateDomainIdentity: "false"` in taskcat params — taskcat runs reuse an SES identity already verified in the dev account.
- PeerTube's user-generated content goes to S3 via the `object_storage:` section of `production.yaml`; CloudFront sits in front for delivery. `base_url` is set to the CloudFront domain, not the S3 bucket.
- `singleton=True` on the ASG is load-bearing — PeerTube is not horizontally scalable in this pattern; the data EBS volume is attached to whichever instance is current.

## Upgrade Workflow

For upgrading the upstream PeerTube version, follow the process in [aws-marketplace-utilities/UPGRADE.md](https://github.com/ordinaryexperts/aws-marketplace-utilities/blob/main/UPGRADE.md).
