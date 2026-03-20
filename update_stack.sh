#!/bin/bash

echo "🔄 INITIATING SYSTEM-WIDE UPDATE..."
echo "-----------------------------------"

# --- PRE-FLIGHT SAFETY CHECK ---
MOUNT_POINT="/mnt/cloud_storage"
if ! mountpoint -q "$MOUNT_POINT"; then
    echo "❌ CRITICAL ERROR: $MOUNT_POINT is NOT mounted!"
    echo "   Aborting update to prevent suffocating the OS drive."
    exit 1
fi
echo "✅ Storage check passed. NVMe is securely mounted."

# 1. Update Docker Containers
echo "📦 1/4: Pulling latest Docker images..."
docker compose pull

echo "🚀 2/4: Recreating containers with new images..."
docker compose up -d --remove-orphans

echo "🧹 3/4: Cleaning up old image debris..."
docker image prune -f

# 2. Update AI Models (Ollama)
echo "🧠 4/4: Updating all local AI models..."
MODELS=$(docker exec ollama ollama list | tail -n +2 | awk '{print $1}')

if [ -z "$MODELS" ]; then
    echo "⚠️ No local models found to update."
else
    for MODEL in $MODELS; do
        echo "⬇️ Pulling latest weights for: $MODEL"
        docker exec ollama ollama pull $MODEL
    done
fi

echo "-----------------------------------"
echo "✅ SYSTEM UPDATE COMPLETE."