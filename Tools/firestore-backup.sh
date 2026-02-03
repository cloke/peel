#!/bin/bash
# Firestore Backup Tool for Peel
# Backs up all Firestore data to a JSON file using Firebase REST API

set -e

PROJECT_ID="peel-swarm"
BACKUP_DIR="${HOME}/peel-backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/firestore_backup_${TIMESTAMP}.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}🔥 Firestore Backup Tool${NC}"
echo "========================="
echo "Project: ${PROJECT_ID}"
echo ""

# Check if firebase CLI is installed
if ! command -v firebase &> /dev/null; then
    echo -e "${RED}Error: firebase CLI not installed${NC}"
    echo "Install with: npm install -g firebase-tools"
    exit 1
fi

# Create backup directory
mkdir -p "${BACKUP_DIR}"

# Get Firebase access token
echo "Getting Firebase access token..."
TOKEN=$(firebase login:ci --no-localhost 2>/dev/null || firebase token:ci 2>/dev/null || echo "")

if [ -z "${TOKEN}" ]; then
    echo "Using existing Firebase auth..."
fi

# Function to fetch a collection via REST API
fetch_collection() {
    local collection=$1
    local parent=${2:-""}
    
    if [ -n "${parent}" ]; then
        local url="https://firestore.googleapis.com/v1/projects/${PROJECT_ID}/databases/(default)/documents/${parent}/${collection}"
    else
        local url="https://firestore.googleapis.com/v1/projects/${PROJECT_ID}/databases/(default)/documents/${collection}"
    fi
    
    curl -s "${url}" 2>/dev/null
}

echo "Backing up Firestore collections..."
echo ""

# Create backup structure
cat > "${BACKUP_FILE}" << EOF
{
  "backupTimestamp": "$(date -Iseconds)",
  "project": "${PROJECT_ID}",
  "collections": {
EOF

# Backup each known collection
COLLECTIONS=("swarms" "users")
FIRST=true

for col in "${COLLECTIONS[@]}"; do
    echo "  Fetching ${col}..."
    
    if [ "${FIRST}" = true ]; then
        FIRST=false
    else
        echo "," >> "${BACKUP_FILE}"
    fi
    
    # Fetch the collection
    DATA=$(fetch_collection "${col}")
    
    # Add to backup file
    echo "    \"${col}\": ${DATA:-"{}"}" >> "${BACKUP_FILE}"
done

# Close JSON
cat >> "${BACKUP_FILE}" << EOF

  }
}
EOF

# Validate JSON
if python3 -m json.tool "${BACKUP_FILE}" > /dev/null 2>&1; then
    SIZE=$(du -h "${BACKUP_FILE}" | cut -f1)
    echo ""
    echo -e "${GREEN}✅ Backup saved to: ${BACKUP_FILE}${NC}"
    echo "   Size: ${SIZE}"
    echo ""
    echo "Preview:"
    python3 -m json.tool "${BACKUP_FILE}" 2>/dev/null | head -30
else
    echo -e "${YELLOW}⚠️  Backup saved but JSON may be malformed${NC}"
    echo "File: ${BACKUP_FILE}"
fi

echo ""
echo "Recent backups:"
ls -lah "${BACKUP_DIR}"/*.json 2>/dev/null | tail -5 || echo "No backups found"
