import os
import subprocess

from aws_cdk import (
    Aws,
    aws_cloudfront,
    aws_iam,
    CfnMapping,
    CfnOutput,
    CfnParameter,
    Stack
)
from constructs import Construct

from oe_patterns_cdk_common.alb import Alb
from oe_patterns_cdk_common.asg import Asg
from oe_patterns_cdk_common.assets_bucket import AssetsBucket
from oe_patterns_cdk_common.aurora_cluster import AuroraPostgresql
from oe_patterns_cdk_common.db_secret import DbSecret
from oe_patterns_cdk_common.dns import Dns
from oe_patterns_cdk_common.elasticache_cluster import ElasticacheRedis
from oe_patterns_cdk_common.ses import Ses
from oe_patterns_cdk_common.util import Util
from oe_patterns_cdk_common.vpc import Vpc

if "TEMPLATE_VERSION" in os.environ:
    template_version = os.environ["TEMPLATE_VERSION"]
else:
    try:
        template_version = subprocess.check_output(["git", "describe", "--always"]).strip().decode('ascii')
    except:
        template_version = "CICD"

AMI_ID="ami-0fb6c6f280aca48dc" # ordinary-experts-patterns-peertube-2.1.0-1-g17c38cd-20250307-0915

class PeertubeStack(Stack):

    def __init__(self, scope: Construct, construct_id: str, **kwargs) -> None:
        super().__init__(scope, construct_id, **kwargs)

        # vpc
        vpc = Vpc(
            self,
            "Vpc"
        )

        self.admin_email_param = CfnParameter(
            self,
            "AdminEmail",
            default="",
            description="Optional: The email address to use for the PeerTube administrator account. If not specified, 'admin@{DnsHostname}' wil be used."
        )

        # dns
        dns = Dns(self, "Dns")

        bucket = AssetsBucket(
            self,
            "AssetsBucket",
            allow_open_cors = True,
            object_ownership_value = "ObjectWriter",
            remove_public_access_block = True
        )

        ses = Ses(
            self,
            "Ses",
            hosted_zone_name=dns.route_53_hosted_zone_name_param.value_as_string,
            additional_iam_user_policies=[bucket.user_policy]
        )

        # db_secret
        db_secret = DbSecret(
            self,
            "DbSecret",
            username = "peertube"
        )

        # redis
        redis = ElasticacheRedis(
            self,
            "Redis",
            vpc=vpc
        )

        asg_update_secret_policy = aws_iam.CfnRole.PolicyProperty(
            policy_document=aws_iam.PolicyDocument(
                statements=[
                    aws_iam.PolicyStatement(
                        effect=aws_iam.Effect.ALLOW,
                        actions=[
                            "secretsmanager:UpdateSecret"
                        ],
                        resources=[
                            f"arn:{Aws.PARTITION}:secretsmanager:{Aws.REGION}:{Aws.ACCOUNT_ID}:secret:{Aws.STACK_NAME}/instance/credentials-*"
                        ]
                    )
                ]
            ),
            policy_name="AllowUpdateInstanceSecret"
        )

        # asg
        with open("peertube/user_data.sh") as f:
            user_data_contents = f.read()
        asg = Asg(
            self,
            "Asg",
            additional_iam_role_policies=[asg_update_secret_policy],
            ami_id=AMI_ID,
            default_instance_type="c7g.medium",
            root_volume_size=100,
            secret_arns=[db_secret.secret_arn(), ses.secret_arn()],
            singleton = True,
            use_data_volume = True,
            use_graviton = True,
            user_data_contents=user_data_contents,
            user_data_variables={
                "AssetsBucketName": bucket.bucket_name(),
                "DbSecretArn": db_secret.secret_arn(),
                "Hostname": dns.hostname(),
                "InstanceSecretName": Aws.STACK_NAME + "/instance/credentials"
            },
            vpc=vpc
        )

        alb = Alb(
            self,
            "Alb",
            asg=asg,
            health_check_path = "/elb-check",
            vpc=vpc
        )

        asg.asg.target_group_arns = [ alb.target_group.ref ]

        # cloudfront
        self.cloudfront_price_class_param = CfnParameter(
            self,
            "CloudFrontPriceClass",
            # possible to use a map to make the values more human readable
            allowed_values = [
                "PriceClass_All",
                "PriceClass_200",
                "PriceClass_100"
            ],
            default="PriceClass_All",
            description="Required: Price class to use for CloudFront CDN."
        )
        cloudfront_distribution = aws_cloudfront.CfnDistribution(
            self,
            "CloudFrontDistribution",
            distribution_config=aws_cloudfront.CfnDistribution.DistributionConfigProperty(
                comment=Aws.STACK_NAME,
                default_cache_behavior=aws_cloudfront.CfnDistribution.DefaultCacheBehaviorProperty(
                    allowed_methods=[
                        "GET",
                        "HEAD",
                        "OPTIONS"
                    ],
                    compress=True,
                    default_ttl=86400,
                    forwarded_values=aws_cloudfront.CfnDistribution.ForwardedValuesProperty(
                        cookies=None,
                        headers=[],
                        query_string=True
                    ),
                    min_ttl=0,
                    max_ttl=31536000,
                    target_origin_id="s3-origin",
                    viewer_protocol_policy="redirect-to-https"
                ),
                enabled=True,
                origins=[
                    aws_cloudfront.CfnDistribution.OriginProperty(
                        domain_name=f"{bucket.bucket_name()}.s3.{Aws.REGION}.amazonaws.com",
                        id="s3-origin",
                        s3_origin_config=aws_cloudfront.CfnDistribution.S3OriginConfigProperty(
                            origin_access_identity=""
                        )
                    )
                ],
                price_class=self.cloudfront_price_class_param.value_as_string,
            )
        )

        db = AuroraPostgresql(
            self,
            "Db",
            database_name="peertube",
            db_secret=db_secret,
            vpc=vpc
        )
        asg.asg.node.add_dependency(db.db_primary_instance)
        asg.asg.node.add_dependency(ses.generate_smtp_password_custom_resource)

        redis_ingress = Util.add_sg_ingress(redis, asg.sg)
        db_ingress    = Util.add_sg_ingress(db, asg.sg)
        
        dns.add_alb(alb)

        CfnOutput(
            self,
            "FirstUseInstructions",
            description="Instructions for getting started",
            value=f"Click on the DnsSiteUrlOutput link and log in with 'root' and the value of 'root_password' in the {Aws.STACK_NAME}/instance/credentials secret in Secrets Manager."
        )

        parameter_groups = [
            {
                "Label": {
                    "default": "Application Config"
                },
                "Parameters": [
                    self.admin_email_param.logical_id
                ]
            },
            {
                "Label": {
                    "default": "CloudFront Config"
                },
                "Parameters": [
                    self.cloudfront_price_class_param.logical_id
                ]
            }
        ]
        parameter_groups += alb.metadata_parameter_group()
        parameter_groups += bucket.metadata_parameter_group()
        parameter_groups += db_secret.metadata_parameter_group()
        parameter_groups += db.metadata_parameter_group()
        parameter_groups += dns.metadata_parameter_group()
        parameter_groups += redis.metadata_parameter_group()
        parameter_groups += asg.metadata_parameter_group()
        parameter_groups += ses.metadata_parameter_group()
        parameter_groups += vpc.metadata_parameter_group()

        # AWS::CloudFormation::Interface
        self.template_options.metadata = {
            "OE::Patterns::TemplateVersion": template_version,
            "AWS::CloudFormation::Interface": {
                "ParameterGroups": parameter_groups,
                "ParameterLabels": {
                    self.admin_email_param.logical_id: {
                        "default": "PeerTube Admin Email"
                    },
                    self.cloudfront_price_class_param.logical_id: {
                        "default": "CloudFront Price Class"
                    },
                    **alb.metadata_parameter_labels(),
                    **bucket.metadata_parameter_labels(),
                    **db_secret.metadata_parameter_labels(),
                    **db.metadata_parameter_labels(),
                    **dns.metadata_parameter_labels(),
                    **redis.metadata_parameter_labels(),
                    **asg.metadata_parameter_labels(),
                    **ses.metadata_parameter_labels(),
                    **vpc.metadata_parameter_labels()
                }
            }
        }
