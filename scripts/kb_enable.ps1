# kb_enable.ps1 — Enable RAG layer (~$0.96/hr while active)
# Usage: .\scripts\kb_enable.ps1

param(
    [string]$Environment = "dev",
    [string]$Region = "us-east-1"
)

Write-Host "Enabling RAG layer (Bedrock Knowledge Base + OpenSearch Serverless)..." -ForegroundColor Yellow
Write-Host "WARNING: This will incur ~`$0.96/hr in charges while active" -ForegroundColor Red

Set-Location infra/terraform

# Apply with RAG enabled
terraform apply -var="enable_rag=true" -var="environment=$Environment" -auto-approve

if ($LASTEXITCODE -ne 0) {
    Write-Host "Terraform apply failed" -ForegroundColor Red
    exit 1
}

# Get outputs
$KB_ID = terraform output -raw knowledge_base_id
$DS_ID = terraform output -raw data_source_id 2>$null

if ($KB_ID -and $DS_ID) {
    Write-Host "Starting KB ingestion job..." -ForegroundColor Cyan
    aws bedrock-agent start-ingestion-job `
        --knowledge-base-id $KB_ID `
        --data-source-id $DS_ID `
        --region $Region

    Write-Host "RAG layer enabled. Knowledge Base ID: $KB_ID" -ForegroundColor Green
    Write-Host "Set env var: `$env:KNOWLEDGE_BASE_ID = '$KB_ID'" -ForegroundColor Cyan
} else {
    Write-Host "RAG enabled but could not retrieve KB ID. Check Terraform outputs." -ForegroundColor Yellow
}

Set-Location ../..
