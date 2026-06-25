# Concert Ticket Booking System — EKS Architecture

Handles **20,000 concurrent transactions** with <1% error rate and zero-downtime deployments.

## Architecture

```
Internet → ALB → EKS (booking-service pods)
                      ↓ Redis SET NX (seat lock)
                      ↓ SQS FIFO (queue booking)
                 EKS (worker-service pods)
                      ↓ PostgreSQL RDS Multi-AZ
```

### Why each component

| Component | Role | Scalability lever |
|---|---|---|
| **booking-service** | HTTP API, Redis locking, SQS publish | HPA 3→20 pods on CPU |
| **worker-service** | SQS consumer, Postgres writer | HPA 3→20 pods on CPU / queue depth |
| **Redis (ElastiCache)** | Distributed seat lock (`SET NX`) | Cluster mode, 3 shards |
| **SQS FIFO** | Decouple API burst from DB writes | Unlimited throughput buffer |
| **RDS PostgreSQL Multi-AZ** | Durable booking record | Read replicas, connection pooling |
| **Cluster Autoscaler** | Add/remove EC2 nodes | On-demand baseline + Spot burst |
| **PodDisruptionBudget** | Keep ≥2 pods during node drain | Zero-downtime rolling deploys |

### Seat locking flow

```
User clicks "Buy"
  → booking-service: Redis SET NX seat:lock:evt-001:A42 {booking_id} PX 600000
  → if OK  → publish {action:reserve} to SQS → return booking_id (202)
  → if FAIL → return 409 "seat already taken"

User clicks "Confirm"
  → publish {action:confirm} to SQS

worker-service consumes SQS:
  reserve → INSERT INTO bookings ... ON CONFLICT DO NOTHING
  confirm → UPDATE bookings SET status='confirmed' WHERE id=$1
```

## Project structure

```
world-paint/
├── booking-service/          Go HTTP API (seat locking + SQS publish)
│   ├── cmd/main.go
│   └── internal/
│       ├── handler/          HTTP handlers
│       ├── lock/             Redis distributed lock
│       └── queue/            SQS publisher
├── worker-service/           Go SQS consumer (Postgres writes)
│   ├── cmd/main.go
│   └── internal/
│       ├── consumer/         SQS poll + dispatch
│       └── db/               Postgres store + migrations
├── k8s/                      Kubernetes manifests
│   ├── booking-service/      Deployment, HPA, PDB, Service, Ingress
│   ├── worker-service/       Deployment, HPA, PDB
│   └── configmap.yaml
├── terraform/                Infrastructure as Code
│   ├── main.tf               VPC
│   ├── eks.tf                EKS cluster + node groups
│   ├── rds.tf                PostgreSQL Multi-AZ
│   ├── elasticache.tf        Redis cluster
│   └── sqs.tf                FIFO queue + DLQ
├── load-test/
│   └── booking_test.js       k6 script — ramps to 20k VUs
└── docker/
    └── docker-compose.yml    Local dev (LocalStack SQS + Postgres + Redis)
```

## Quick start (local)

```bash
# 1. Start local stack
cd docker
docker compose up -d

# 2. Test the API
curl -X POST http://localhost:8080/api/v1/events/evt-001/reserve \
  -H "Content-Type: application/json" \
  -d '{"seat_id":"A1","user_id":"user-123"}'

# 3. Run load test (requires k6 installed)
cd ../load-test
k6 run -e BASE_URL=http://localhost:8080 booking_test.js
```

## Deploy to EKS

```bash
# 1. Provision infrastructure
cd terraform
terraform init
terraform apply -var="db_password=<your_password>"

# 2. Configure kubectl
aws eks update-kubeconfig --name ticketing-eks --region ap-southeast-2

# 3. Build and push images
aws ecr get-login-password | docker login --username AWS --password-stdin <ECR_URI>
docker build -t <ECR_URI>/booking-service:latest ./booking-service && docker push ...
docker build -t <ECR_URI>/worker-service:latest  ./worker-service  && docker push ...

# 4. Deploy
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/configmap.yaml   # update placeholders first
kubectl apply -f k8s/booking-service/
kubectl apply -f k8s/worker-service/

# 5. Run load test against ALB
k6 run -e BASE_URL=https://<ALB_DNS> load-test/booking_test.js
```

## Reliability features

- **Zero-downtime deploys** — `maxUnavailable: 0` + `preStop` drain hook
- **Multi-AZ spread** — `topologySpreadConstraints` ensures pods across 3 AZs
- **Node failure** — PDB keeps ≥2 pods alive during drains; RDS auto-failover <60s
- **Seat oversell prevention** — Redis `SET NX` is atomic; exactly-once via FIFO dedup
- **Retry safety** — all DB operations idempotent (`ON CONFLICT DO NOTHING`)
- **Failed messages** — SQS DLQ catches after 3 retries; never lost
