import re

import aws_cdk as cdk
from aws_cdk import (
    CfnOutput,
    Duration,
    RemovalPolicy,
    Stack,
    Tags,
    aws_ec2 as ec2,
    aws_ecr as ecr,
    aws_ecs as ecs,
    aws_elasticloadbalancingv2 as elbv2,
    aws_iam as iam,
    aws_logs as logs,
    aws_rds as rds,
)
from constructs import Construct


def safe_preview_id(value: str) -> str:
    """Make a predictable, short value safe for CFN names, tags and image tags."""
    result = re.sub(r"[^a-z0-9-]+", "-", value.lower()).strip("-")
    if not result:
        raise ValueError("preview_id must contain a letter or number")
    return result[:32].rstrip("-")


def preview_stack_name(preview_id: str) -> str:
    return f"Preview-{safe_preview_id(preview_id)}"


class PlatformStack(Stack):
    """Long-lived, shared building blocks. Deploy this once before any preview."""

    def __init__(self, scope: Construct, construct_id: str, *, github_subject: str, **kwargs) -> None:
        super().__init__(scope, construct_id, **kwargs)

        self.vpc = ec2.Vpc(
            self,
            "Vpc",
            max_azs=2,
            nat_gateways=0,
            subnet_configuration=[
                ec2.SubnetConfiguration(
                    name="public", subnet_type=ec2.SubnetType.PUBLIC, cidr_mask=24
                )
            ],
        )
        self.cluster = ecs.Cluster(self, "Cluster", vpc=self.vpc, container_insights_v2=ecs.ContainerInsights.ENHANCED)
        self.log_group = logs.LogGroup(
            self, "PreviewLogs", retention=logs.RetentionDays.ONE_WEEK, removal_policy=RemovalPolicy.DESTROY
        )
        self.service_a_repository = ecr.Repository(
            self,
            "ServiceARepository",
            repository_name="preview-catalog-service",
            image_scan_on_push=True,
            removal_policy=RemovalPolicy.DESTROY,
            empty_on_delete=True,
        )
        self.service_b_repository = ecr.Repository(
            self,
            "ServiceBRepository",
            repository_name="preview-orders-service",
            image_scan_on_push=True,
            removal_policy=RemovalPolicy.DESTROY,
            empty_on_delete=True,
        )

        # Fresh challenge accounts normally have no GitHub OIDC provider. Import it instead if
        # the account is already managed by another IaC stack.
        provider = iam.OpenIdConnectProvider(
            self,
            "GitHubOidcProvider",
            url="https://token.actions.githubusercontent.com",
            client_ids=["sts.amazonaws.com"],
        )
        self.github_actions_role = iam.Role(
            self,
            "GitHubActionsRole",
            assumed_by=iam.WebIdentityPrincipal(
                provider.open_id_connect_provider_arn,
                conditions={
                    "StringEquals": {
                        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
                        "token.actions.githubusercontent.com:sub": github_subject,
                    },
                },
            ),
            description="Challenge CI role; replace AdministratorAccess with a scoped policy in production.",
        )
        self.github_actions_role.add_managed_policy(
            iam.ManagedPolicy.from_aws_managed_policy_name("AdministratorAccess")
        )

        CfnOutput(self, "GitHubActionsRoleArn", value=self.github_actions_role.role_arn)
        CfnOutput(self, "ServiceARepositoryUri", value=self.service_a_repository.repository_uri)
        CfnOutput(self, "ServiceBRepositoryUri", value=self.service_b_repository.repository_uri)


class PreviewEnvironmentStack(Stack):
    """A disposable ALB + two tasks + PostgreSQL database for one feature group."""

    def __init__(
        self,
        scope: Construct,
        construct_id: str,
        *,
        platform: PlatformStack,
        preview_id: str,
        is_baseline: bool,
        snapshot_identifier: str | None,
        service_a_image: str | None,
        service_b_image: str | None,
        **kwargs,
    ) -> None:
        super().__init__(scope, construct_id, **kwargs)
        if not service_a_image or not service_b_image:
            raise ValueError("service_a_image and service_b_image CDK context values are required")

        name = safe_preview_id(preview_id)
        Tags.of(self).add("Project", "ephemeral-previews")
        Tags.of(self).add("Preview", name)
        Tags.of(self).add("ManagedBy", "CDK")

        alb_sg = ec2.SecurityGroup(self, "AlbSecurityGroup", vpc=platform.vpc, description="Public preview HTTP")
        alb_sg.add_ingress_rule(ec2.Peer.any_ipv4(), ec2.Port.tcp(80), "Public HTTP for reviewer")
        app_sg = ec2.SecurityGroup(self, "AppSecurityGroup", vpc=platform.vpc, description="Preview API tasks")
        app_sg.add_ingress_rule(alb_sg, ec2.Port.tcp(8000), "ALB to FastAPI")
        database_sg = ec2.SecurityGroup(self, "DatabaseSecurityGroup", vpc=platform.vpc, description="Preview PostgreSQL")
        database_sg.add_ingress_rule(app_sg, ec2.Port.tcp(5432), "API tasks to PostgreSQL")

        database_config = dict(
            # Pin to a version currently offered in us-east-2; newer patch releases can be
            # selected when the CDK library is upgraded.
            engine=rds.DatabaseInstanceEngine.postgres(version=rds.PostgresEngineVersion.VER_16_9),
            vpc=platform.vpc,
            vpc_subnets=ec2.SubnetSelection(subnet_type=ec2.SubnetType.PUBLIC),
            publicly_accessible=False,
            security_groups=[database_sg],
            instance_type=ec2.InstanceType.of(ec2.InstanceClass.BURSTABLE3, ec2.InstanceSize.MICRO),
            allocated_storage=20,
            backup_retention=Duration.days(1),
            deletion_protection=False,
            delete_automated_backups=True,
            removal_policy=RemovalPolicy.DESTROY,
        )
        if is_baseline:
            # The long-lived source database. Its data is captured immediately before each
            # preview deployment, not at a schedule that might be stale.
            database = rds.DatabaseInstance(
                self,
                "Database",
                database_name="app",
                credentials=rds.Credentials.from_generated_secret("appuser"),
                **database_config,
            )
        else:
            if not snapshot_identifier:
                raise ValueError("snapshot_identifier is required for every preview database")
            # A snapshot restore retains the source application's data. New generated master
            # credentials make the preview independently accessible and disposable.
            database = rds.DatabaseInstanceFromSnapshot(
                self,
                "Database",
                snapshot_identifier=snapshot_identifier,
                credentials=rds.SnapshotCredentials.from_generated_secret("appuser"),
                **database_config,
            )

        load_balancer = elbv2.ApplicationLoadBalancer(
            self, "LoadBalancer", vpc=platform.vpc, internet_facing=True, security_group=alb_sg
        )
        listener = load_balancer.add_listener("Http", port=80, open=False)

        service_a = self._api_service(
            "ServiceA", platform, app_sg, database, service_a_image, "catalog-service", "/a"
        )
        service_b = self._api_service(
            "ServiceB", platform, app_sg, database, service_b_image, "orders-service", "/b"
        )
        listener.add_targets(
            "ServiceATarget",
            priority=10,
            conditions=[elbv2.ListenerCondition.path_patterns(["/a", "/a/*"])],
            port=8000,
            targets=[service_a],
            health_check=elbv2.HealthCheck(path="/a/health", healthy_http_codes="200"),
        )
        listener.add_targets(
            "ServiceBTarget",
            priority=20,
            conditions=[elbv2.ListenerCondition.path_patterns(["/b", "/b/*"])],
            port=8000,
            targets=[service_b],
            health_check=elbv2.HealthCheck(path="/b/health", healthy_http_codes="200"),
        )
        listener.add_action(
            "NotFound",
            action=elbv2.ListenerAction.fixed_response(404, content_type="application/json", message_body='{"detail":"use /a or /b"}'),
        )

        CfnOutput(self, "PreviewUrl", value=f"http://{load_balancer.load_balancer_dns_name}")
        CfnOutput(self, "CatalogUrl", value=f"http://{load_balancer.load_balancer_dns_name}/a/health")
        CfnOutput(self, "OrdersUrl", value=f"http://{load_balancer.load_balancer_dns_name}/b/health")
        CfnOutput(self, "DatabaseEndpoint", value=database.instance_endpoint.hostname)
        if is_baseline:
            CfnOutput(self, "BaselineDatabaseIdentifier", value=database.instance_identifier)

    def _api_service(
        self,
        logical_name: str,
        platform: PlatformStack,
        app_sg: ec2.ISecurityGroup,
        database: rds.DatabaseInstance,
        image: str,
        service_name: str,
        path_prefix: str,
    ) -> ecs.FargateService:
        task = ecs.FargateTaskDefinition(self, f"{logical_name}Task", cpu=256, memory_limit_mib=512)
        # The application itself has no AWS API permissions. Its execution role needs the
        # standard ECR, CloudWatch Logs, and Secrets Manager bootstrap permissions before
        # Fargate can pull a private image and inject the database password.
        task.execution_role.add_managed_policy(
            iam.ManagedPolicy.from_aws_managed_policy_name("service-role/AmazonECSTaskExecutionRolePolicy")
        )
        container = task.add_container(
            "Api",
            image=ecs.ContainerImage.from_registry(image),
            logging=ecs.LogDrivers.aws_logs(stream_prefix=service_name, log_group=platform.log_group),
            environment={
                "SERVICE_NAME": service_name,
                "PATH_PREFIX": path_prefix,
                "DB_HOST": database.instance_endpoint.hostname,
                "DB_PORT": str(database.instance_endpoint.port),
                "DB_NAME": "app",
                "DB_USER": "appuser",
            },
            secrets={"DB_PASSWORD": ecs.Secret.from_secrets_manager(database.secret, "password")},
        )
        container.add_port_mappings(ecs.PortMapping(container_port=8000))
        return ecs.FargateService(
            self,
            logical_name,
            cluster=platform.cluster,
            task_definition=task,
            desired_count=1,
            assign_public_ip=True,
            security_groups=[app_sg],
            vpc_subnets=ec2.SubnetSelection(subnet_type=ec2.SubnetType.PUBLIC),
            health_check_grace_period=Duration.minutes(5),
            min_healthy_percent=100,
            max_healthy_percent=200,
        )
