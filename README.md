# Federated Learning on AWS IoT Greengrass

A distributed machine learning system that trains a shared model across 10 edge devices without centralizing raw data — built on AWS IoT Greengrass, MQTT, EC2, Lambda, and S3.

---

## What This Project Does

Traditional ML requires sending all data to a central server for training. **Federated Learning (FL)** flips this — each device trains locally on its own data and only sends model updates (weights) to the cloud, not the raw data itself. This preserves privacy and enables real-world edge deployment.

This project simulates 10 IoT edge devices using EC2 instances running AWS IoT Greengrass Core, trains a neural network on MNIST digit classification across 5 federated rounds, and aggregates local model updates in the cloud using AWS Lambda.

**Final Results:**
- ✅ 97.39% classification accuracy after 5 rounds
- ⚡ Full training completed in 46.7 seconds across 10 workers
- 📦 All global/local models and per-round metrics stored in S3

---

## Architecture

```
                        ┌─────────────────────────────┐
                        │         AWS Cloud            │
                        │                              │
                        │   ┌──────────┐  ┌────────┐  │
                        │   │    S3    │  │ Lambda │  │
                        │   │ (global/ │◄─│Aggreg- │  │
                        │   │  local   │  │ ator   │  │
                        │   │ models)  │  └────────┘  │
                        │   └──────────┘              │
                        └────────────┬────────────────┘
                                     │ MQTT (next-round trigger)
              ┌──────────────────────┼──────────────────────┐
              │                      │                      │
   ┌──────────▼──────┐    ┌──────────▼──────┐   ┌──────────▼──────┐
   │  IoT Greengrass │    │  IoT Greengrass │   │  IoT Greengrass │
   │  Worker 0       │    │  Worker 1       │   │  Worker 9       │
   │  (EC2 t3.micro) │    │  (EC2 t3.micro) │   │  (EC2 t3.micro) │
   │  Local Training │    │  Local Training │   │  Local Training │
   └─────────────────┘    └─────────────────┘   └─────────────────┘
         EDGE LAYER (10 workers total)
```

**How a single round works:**
1. MQTT message triggers all 10 workers to start the next round
2. Each worker downloads the current global model from S3
3. Each worker trains locally for 5 epochs on its data partition
4. Each worker uploads its updated local model to S3
5. Lambda aggregator merges all 10 local models (FedAvg) into a new global model
6. MQTT triggers the next round — repeated for 5 rounds total

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Edge Runtime | AWS IoT Greengrass Core v2 |
| Messaging | MQTT (AWS IoT Core) |
| Compute | AWS EC2 (t3.micro × 10) |
| Aggregation | AWS Lambda |
| Storage | AWS S3 (global + local buckets) |
| ML Framework | PyTorch (MNIST neural network) |
| Language | Python |

---

## Key Design Decisions

### Why Separate Global and Local S3 Buckets?
- **Global bucket** — stores the shared global model and training metrics, readable by all workers
- **Local bucket** — each worker uploads its local model update here, only written to by workers and read by the aggregator

### Why MQTT for Round Triggering?
MQTT is the standard IoT messaging protocol. Using it here simulates real-world IoT deployments where edge devices wait for cloud instructions rather than polling constantly.

### Why IoT Greengrass?
Greengrass lets you deploy and manage software components on edge devices remotely. Each worker runs a Greengrass **component** (the FL worker script) that subscribes to MQTT and handles training — just like a real IoT device would.

---

## Results

| Round | Accuracy | Loss |
|-------|----------|------|
| 0 | 90.26% | 0.3277 |
| 1 | 95.58% | 0.1258 |
| 2 | 97.19% | 0.0961 |
| 3 | 97.39% | 0.0885 |
| 4 | 97.39% | 0.0830 |

- **Total training time:** 46.7 seconds (5 rounds, 10 workers)
- **All artifacts verified:** global models, local models, and metrics stored per round in S3

---

## Project Structure

```
federated-learning-greengrass/
│
├── worker/
│   └── worker.py            # FL worker component (runs on each edge device)
│
├── aggregator/
│   └── aggregator.py        # Lambda aggregator (FedAvg on local model updates)
│
├── greengrass/
│   └── recipes/
│       └── com.fl.Worker-1.0.0.json   # Greengrass component recipe
│
└── README.md
```

---

## Setup Overview

> ⚠️ This project requires an AWS account with IoT Greengrass, EC2, Lambda, S3, and IoT Core access.

### 1. Provision EC2 Workers
Launch 10 EC2 instances (t3.micro) in `us-west-2`. Name them `<ID>-fl-worker-0` through `<ID>-fl-worker-9`.

### 2. Install IoT Greengrass Core on Each Worker
```bash
sudo apt update && sudo apt install -y default-jdk
sudo useradd --system --create-home ggc_user
sudo groupadd --system ggc_group

# Download and install Greengrass
curl -s https://d2s8p88vqu9w66.cloudfront.net/releases/greengrass-nucleus-latest.zip \
  > greengrass-nucleus-latest.zip
unzip greengrass-nucleus-latest.zip -d GreengrassInstaller

sudo -E java -Droot="/greengrass/v2" -Dlog.store=FILE \
  -jar ./GreengrassInstaller/lib/Greengrass.jar \
  --aws-region us-west-2 \
  --thing-name <ID>-fl-worker-<N>-gg \
  --provision true \
  --setup-system-service true
```

### 3. Deploy the Worker Component
```bash
sudo /greengrass/v2/bin/greengrass-cli deployment create \
  --recipeDir ~/greengrassv2/recipes \
  --artifactDir ~/greengrassv2/artifacts \
  --merge "com.fl.Worker=1.0.0"
```

### 4. Deploy the Lambda Aggregator
Deploy `aggregator.py` as an AWS Lambda function named `fl-aggregator`. Attach S3 read/write permissions.

### 5. Create S3 Buckets
```bash
aws s3 mb s3://<ID>-global-bucket --region us-west-2
aws s3 mb s3://<ID>-local-bucket --region us-west-2
```

### 6. Start Training
Upload the initial global model to S3 and publish the first MQTT message to kick off round 0:
```bash
aws iot-data publish \
  --topic "fl/<ID>/next-round" \
  --payload '{"round_number": 0, "num_rounds": 5}' \
  --region us-west-2
```

---

## Key Concepts

**Federated Averaging (FedAvg):** The aggregator averages the weights from all 10 local models to produce the next global model. No raw training data ever leaves the edge device.

**IoT Greengrass Component:** A self-contained software module deployed to edge devices. The worker component subscribes to MQTT, trains locally, and uploads model updates — all autonomously.

**MQTT Pub/Sub:** Lightweight messaging protocol used to trigger each FL round across all workers simultaneously without polling.
