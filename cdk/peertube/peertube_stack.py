import os
import subprocess

from aws_cdk import (
    Aws,
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
        template_version = subprocess.check_output(["git", "describe"]).strip().decode("ascii")
    except:
        template_version = "CICD"

# AMI list generated by:
# make TEMPLATE_VERSION=1.1.0 ami-ec2-build
# on Thu Mar 23 03:26:44 UTC 2023.
AMI_ID="ami-076e9cbb60d5c725c"
AMI_NAME="ordinary-experts-patterns-peertube--20230517-0754"
generated_ami_ids = {
    "ap-northeast-1": "ami-XXXXXXXXXXXXXXXXX",
    "ap-northeast-2": "ami-XXXXXXXXXXXXXXXXX",
    "ap-south-1": "ami-XXXXXXXXXXXXXXXXX",
    "ap-southeast-1": "ami-XXXXXXXXXXXXXXXXX",
    "ap-southeast-2": "ami-XXXXXXXXXXXXXXXXX",
    "ca-central-1": "ami-XXXXXXXXXXXXXXXXX",
    "eu-central-1": "ami-XXXXXXXXXXXXXXXXX",
    "eu-north-1": "ami-XXXXXXXXXXXXXXXXX",
    "eu-west-1": "ami-XXXXXXXXXXXXXXXXX",
    "eu-west-2": "ami-XXXXXXXXXXXXXXXXX",
    "eu-west-3": "ami-XXXXXXXXXXXXXXXXX",
    "sa-east-1": "ami-XXXXXXXXXXXXXXXXX",
    "us-east-2": "ami-XXXXXXXXXXXXXXXXX",
    "us-west-1": "ami-XXXXXXXXXXXXXXXXX",
    "us-west-2": "ami-XXXXXXXXXXXXXXXXX",
    "us-east-1": "ami-076e9cbb60d5c725c"
}
# End generated code block.

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
            description="Optional: The email address to use for the administrator account. If not specified, 'admin@{DnsHostname}' wil be used."
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
            default_instance_type="t3.small",
            root_volume_size=20,
            secret_arns=[db_secret.secret_arn(), ses.secret_arn()],
            singleton = True,
            use_data_volume = True,
            use_graviton = False,
            user_data_contents=user_data_contents,
            user_data_variables={
                "AssetsBucketName": bucket.bucket_name(),
                "DbSecretArn": db_secret.secret_arn(),
                "Hostname": dns.hostname(),
                "HostedZoneName": dns.route_53_hosted_zone_name_param.value_as_string,
                "InstanceSecretName": Aws.STACK_NAME + "/instance/credentials"
            },
            vpc=vpc
        )

        ami_mapping={ "AMI": { "OEAMI": AMI_NAME } }
        for region in generated_ami_ids.keys():
            ami_mapping[region] = { "AMI": generated_ami_ids[region] }
        aws_ami_region_map = CfnMapping(
            self,
            "AWSAMIRegionMap",
            mapping=ami_mapping
        )

        alb = Alb(
            self,
            "Alb",
            asg=asg,
            health_check_path = "/elb-check",
            vpc=vpc
        )

        asg.asg.target_group_arns = [ alb.target_group.ref ]

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