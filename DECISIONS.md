# Architecture decisions

## Process and trade-offs

Feature groups use the visible `fg/<name>` branch convention. A central workflow resolves both refs, tests their containers, builds/pushes their images, and deploys a deterministic CDK stack. Each preview is restored from a just-created snapshot of the baseline RDS PostgreSQL instance, then gets fresh database credentials. This preserves representative baseline data while keeping each environment disposable.

ECS/Fargate, ALB and RDS provide clear AWS primitives for isolated compute, networking and data. Public subnets are used for the internet-facing load balancer and tasks; RDS remains private. A hardened production deployment should use private task subnets with NAT or VPC endpoints, a GitHub App rather than a PAT, a least-privilege deployment role, TTL cleanup, migrations, observability and sanitized production data.

## Operational assessment

The paired-branch lifecycle, test gate, isolated restored data and teardown behavior provide clear operational boundaries. The small applications keep the design focused on the infrastructure and allow the service contract to be exercised end to end.

## What would I change?

For larger deployments, I would evaluate a shared multi-tenant database cluster with per-preview databases to reduce restore time, plus protected deployment environments and richer integration tests.

## Known trade-off

The central tension is strict per-preview database isolation versus startup time and resource usage. Snapshot restore is the clearest data-fidelity solution; a shared-cluster approach is the likely optimization when environment count or restore latency becomes material.
