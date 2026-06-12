#!/bin/bash
# Daily Cloud Photo - AWS デプロイスクリプト
# 使い方: ./deploy.sh [stack-name] [region]

set -e

STACK_NAME="${1:-daily-cloud-photo}"
REGION="${2:-ap-northeast-1}"
BUCKET="${STACK_NAME}-deploy-$(aws sts get-caller-identity --query Account --output text)"

echo "=== Daily Cloud Photo Deploy ==="
echo "Stack: $STACK_NAME"
echo "Region: $REGION"
echo "Deploy Bucket: $BUCKET"
echo ""

# 1. デプロイ用 S3 バケットを作成（既にあればスキップ）
echo "[1/5] Creating deploy bucket..."
aws s3 mb "s3://$BUCKET" --region "$REGION" 2>/dev/null || true

# 2. Lambda ZIP をアップロード
echo "[2/5] Uploading Lambda code..."
aws s3 cp lambda/lambda.zip "s3://$BUCKET/lambda.zip" --region "$REGION"

# 3. Pillow Layer をダウンロード（GitHub Releases から）
echo "[3/5] Downloading Pillow Layer..."
LAYER_URL=$(curl -s https://api.github.com/repos/daily-cloud-app/photo-infra/releases/latest | grep "browser_download_url.*pillow-layer.zip" | cut -d '"' -f 4)
if [ -n "$LAYER_URL" ]; then
  curl -L -o pillow-layer.zip "$LAYER_URL"
  aws s3 cp pillow-layer.zip "s3://$BUCKET/pillow-layer.zip" --region "$REGION"
  echo "  Pillow Layer uploaded."
else
  echo "  WARNING: Pillow Layer not found. Thumbnail generation will not work."
fi

# 4. テンプレートをアップロード
echo "[4/5] Uploading CloudFormation template..."
aws s3 cp template.yaml "s3://$BUCKET/template.yaml" --region "$REGION"

# 5. CloudFormation スタックを作成/更新
echo "[5/5] Deploying CloudFormation stack..."
if aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" >/dev/null 2>&1; then
  echo "  Updating existing stack..."
  aws cloudformation update-stack \
    --stack-name "$STACK_NAME" \
    --template-url "https://$BUCKET.s3.$REGION.amazonaws.com/template.yaml" \
    --parameters \
      ParameterKey=LambdaCodeBucket,ParameterValue="$BUCKET" \
      ParameterKey=LambdaCodeKey,ParameterValue=lambda.zip \
    --capabilities CAPABILITY_NAMED_IAM \
    --region "$REGION"
  aws cloudformation wait stack-update-complete --stack-name "$STACK_NAME" --region "$REGION"
else
  echo "  Creating new stack..."
  aws cloudformation create-stack \
    --stack-name "$STACK_NAME" \
    --template-url "https://$BUCKET.s3.$REGION.amazonaws.com/template.yaml" \
    --parameters \
      ParameterKey=LambdaCodeBucket,ParameterValue="$BUCKET" \
      ParameterKey=LambdaCodeKey,ParameterValue=lambda.zip \
    --capabilities CAPABILITY_NAMED_IAM \
    --region "$REGION"
  aws cloudformation wait stack-create-complete --stack-name "$STACK_NAME" --region "$REGION"
fi

# 完了
echo ""
echo "=== Deploy Complete ==="
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs' \
  --output table \
  --region "$REGION"
