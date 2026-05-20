#!/bin/bash

KEY_FILE="fl-key.pem"
ASU_ID="1233745983"
REGION="us-west-2"
SSH_USER="ubuntu"
VERSION="1.0.11"

echo "Fetching IoT endpoint..."
IOT_ENDPOINT=$(aws iot describe-endpoint --endpoint-type iot:Data-ATS --region $REGION --query endpointAddress --output text)
echo "IoT Endpoint: $IOT_ENDPOINT"

echo "Fetching public IPs..."
INSTANCE_IPS=()
for i in $(seq 0 9); do
    IP=$(aws ec2 describe-instances \
        --region $REGION \
        --filters "Name=tag:Name,Values=${ASU_ID}-fl-worker-${i}" "Name=instance-state-name,Values=running" \
        --query "Reservations[0].Instances[0].PublicIpAddress" \
        --output text)
    INSTANCE_IPS+=($IP)
    echo "  worker-${i}: $IP"
done

deploy_worker() {
    local WORKER_ID=$1
    local IP=$2

    echo ""
    echo "=========================================="
    echo " Deploying worker-${WORKER_ID} ($IP)"
    echo "=========================================="

    scp -i "$KEY_FILE" -o StrictHostKeyChecking=no worker.py ${SSH_USER}@${IP}:/tmp/worker.py

    ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no ${SSH_USER}@${IP} bash << EOF

sudo chmod 755 /home/ubuntu
sudo chmod 755 /home/ubuntu/.local
sudo chmod 755 /home/ubuntu/.local/lib
sudo chmod 755 /home/ubuntu/.local/lib/python3.10
sudo chmod -R 755 /home/ubuntu/.local/lib/python3.10/site-packages
sudo chmod 644 /greengrass/v2/privKey.key /greengrass/v2/thingCert.crt /greengrass/v2/rootCA.pem

mkdir -p ~/greengrassv2/recipes
mkdir -p ~/greengrassv2/artifacts/com.fl.Worker/${VERSION}
cp /tmp/worker.py ~/greengrassv2/artifacts/com.fl.Worker/${VERSION}/worker.py

cat > ~/greengrassv2/recipes/com.fl.Worker-${VERSION}.json << RECIPE
{
  "RecipeFormatVersion": "2020-01-25",
  "ComponentName": "com.fl.Worker",
  "ComponentVersion": "${VERSION}",
  "ComponentDescription": "Federated Learning Worker Component",
  "ComponentPublisher": "CSE546",
  "ComponentConfiguration": {
    "DefaultConfiguration": {
      "PARTITION_ID": "${WORKER_ID}",
      "ASU_ID": "${ASU_ID}",
      "IOT_ENDPOINT": "${IOT_ENDPOINT}"
    }
  },
  "Manifests": [
    {
      "Platform": {
        "os": "linux"
      },
      "Lifecycle": {
        "Run": {
          "Script": "PYTHONPATH=/home/ubuntu/.local/lib/python3.10/site-packages PARTITION_ID={configuration:/PARTITION_ID} ASU_ID={configuration:/ASU_ID} IOT_ENDPOINT={configuration:/IOT_ENDPOINT} /usr/bin/python3 {artifacts:path}/worker.py",
          "RequiresPrivilege": true
        }
      },
      "Artifacts": [
        {
          "URI": "s3://PLACEHOLDER/worker.py"
        }
      ]
    }
  ]
}
RECIPE

echo "Recipe written for worker-${WORKER_ID}"

sudo /greengrass/v2/bin/greengrass-cli deployment create \
    --recipeDir ~/greengrassv2/recipes \
    --artifactDir ~/greengrassv2/artifacts \
    --merge "com.fl.Worker=${VERSION}"

echo "Deployment triggered for worker-${WORKER_ID}"
EOF
}

for i in $(seq 0 9); do
    deploy_worker $i ${INSTANCE_IPS[$i]}
done

echo ""
echo "=========================================="
echo " All deployments triggered!"
echo " Waiting 40s then checking component status..."
echo "=========================================="
sleep 40

for i in $(seq 0 9); do
    IP=${INSTANCE_IPS[$i]}
    echo ""
    echo "--- worker-${i} component list ---"
    ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no ${SSH_USER}@${IP} \
        "sudo /greengrass/v2/bin/greengrass-cli component list 2>/dev/null | grep -A2 'com.fl.Worker'"
done
