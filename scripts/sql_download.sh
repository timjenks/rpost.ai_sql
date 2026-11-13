
#!/usr/bin/env bash
set -euo pipefail

BUCKET="${1:?Usage: $0 <bucket> <prefix> <regex> <local-dir>}"
PREFIX="${2:?Missing prefix}"
REGEX="${3:?Missing regex}"
DEST="${4:?Missing destination directory}"

mkdir -p "$DEST"

aws s3api list-objects-v2 \
    --bucket "$BUCKET" \
    --prefix "$PREFIX" \
    --query 'Contents[].Key' \
    --output json |
jq -r '.[]?' |
while IFS= read -r key; do
    filename="${key##*/}"

    # Apply regex to filename only
    if [[ "$filename" =~ $REGEX ]]; then
        echo "Downloading: $key"
        aws s3 cp "s3://$BUCKET/$key" "$DEST/$filename"
    fi
done

echo "Download complete."

