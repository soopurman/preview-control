# Take-home responses

## Process and trade-offs

Feature groups use the visible `fg/<name>` branch convention. A central workflow resolves both refs, tests their containers, builds/pushes their images, and deploys a deterministic CDK stack. Each preview is restored from a just-created snapshot of the baseline RDS PostgreSQL instance, then gets fresh database credentials. This is a realistic data-clone strategy while keeping each preview disposable.

I chose ECS/Fargate, ALB and RDS because they are clear AWS primitives for isolated compute, networking and data. Public-only subnets avoid NAT-gateway cost; RDS stays private. In production I would use private task subnets/NAT or VPC endpoints, a GitHub App rather than a PAT, a least-privilege deployment role, TTL cleanup, migrations, observability and sanitised production data.

## Am I happy with it?

Yes. The paired-branch lifecycle, test gate, isolated restored data and teardown behavior are concrete and easy to demonstrate. The small applications keep the design review focused on the infrastructure.

## What would I change?

For production, I would use a shared multi-tenant database cluster with per-preview databases to reduce preview cost and restore time, plus protected deployment environments and richer integration tests.

## Did I get stuck?

The central tension was strict per-preview database isolation versus cost and startup time. Snapshot restore is the clearest data-fidelity solution for this take-home; a shared-cluster approach would be the production cost optimization.
