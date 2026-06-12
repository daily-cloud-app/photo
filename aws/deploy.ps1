# Daily Cloud Photo - AWS デプロイスクリプト (PowerShell)
# 使い方: .\deploy.ps1 [-StackName "daily-cloud-photo"] [-Region "ap-northeast-1"]

param(
    [string]$StackName = "daily-cloud-photo",
    [string]$Region = "ap-northeast-1"
)

$ErrorActionPreference = "Stop"
$Account = (aws sts get-caller-identity --query Account --output text)
$Bucket = "$StackName-deploy-$Account"

Write-Host "=== Daily Cloud Photo Deploy ===" -ForegroundColor Cyan
Write-Host "Stack: $StackName"
Write-Host "Region: $Region"
Write-Host "Deploy Bucket: $Bucket"
Write-Host ""

# 1. デプロイ用 S3 バケットを作成
Write-Host "[1/5] Creating deploy bucket..." -ForegroundColor Yellow
aws s3 mb "s3://$Bucket" --region $Region 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "  Bucket already exists." }

# 2. Lambda ZIP をアップロード
Write-Host "[2/5] Uploading Lambda code..." -ForegroundColor Yellow
aws s3 cp lambda/lambda.zip "s3://$Bucket/lambda.zip" --region $Region

# 3. Pillow Layer をダウンロード（GitHub Releases から）
Write-Host "[3/5] Downloading Pillow Layer..." -ForegroundColor Yellow
try {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/daily-cloud-app/photo-infra/releases/latest"
    $layerAsset = $release.assets | Where-Object { $_.name -eq "pillow-layer.zip" } | Select-Object -First 1
    if ($layerAsset) {
        Invoke-WebRequest -Uri $layerAsset.browser_download_url -OutFile "pillow-layer.zip"
        aws s3 cp pillow-layer.zip "s3://$Bucket/pillow-layer.zip" --region $Region
        Write-Host "  Pillow Layer uploaded."
    } else {
        Write-Host "  WARNING: Pillow Layer not found in release." -ForegroundColor Red
    }
} catch {
    Write-Host "  WARNING: Could not download Pillow Layer. Thumbnail generation will not work." -ForegroundColor Red
}

# 4. テンプレートをアップロード
Write-Host "[4/5] Uploading CloudFormation template..." -ForegroundColor Yellow
aws s3 cp template.yaml "s3://$Bucket/template.yaml" --region $Region

# 5. CloudFormation スタックを作成/更新
Write-Host "[5/5] Deploying CloudFormation stack..." -ForegroundColor Yellow
$stackExists = aws cloudformation describe-stacks --stack-name $StackName --region $Region 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  Updating existing stack..."
    aws cloudformation update-stack `
        --stack-name $StackName `
        --template-url "https://$Bucket.s3.$Region.amazonaws.com/template.yaml" `
        --parameters "ParameterKey=LambdaCodeBucket,ParameterValue=$Bucket" "ParameterKey=LambdaCodeKey,ParameterValue=lambda.zip" `
        --capabilities CAPABILITY_NAMED_IAM `
        --region $Region
    aws cloudformation wait stack-update-complete --stack-name $StackName --region $Region
} else {
    Write-Host "  Creating new stack..."
    aws cloudformation create-stack `
        --stack-name $StackName `
        --template-url "https://$Bucket.s3.$Region.amazonaws.com/template.yaml" `
        --parameters "ParameterKey=LambdaCodeBucket,ParameterValue=$Bucket" "ParameterKey=LambdaCodeKey,ParameterValue=lambda.zip" `
        --capabilities CAPABILITY_NAMED_IAM `
        --region $Region
    aws cloudformation wait stack-create-complete --stack-name $StackName --region $Region
}

# 完了
Write-Host ""
Write-Host "=== Deploy Complete ===" -ForegroundColor Green
aws cloudformation describe-stacks --stack-name $StackName --query "Stacks[0].Outputs" --output table --region $Region
