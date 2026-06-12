# kb_disable.ps1 — Disable RAG layer (destroys OpenSearch, preserves Gold data)
# Usage: .\scripts\kb_disable.ps1

param(
    [string]$Environment = "dev"
)

Write-Host "Disabling RAG layer..." -ForegroundColor Yellow
Write-Host "OpenSearch Serverless will be destroyed. Gold S3 data is preserved." -ForegroundColor Cyan

Set-Location infra/terraform

terraform apply -var="enable_rag=false" -var="environment=$Environment" -auto-approve

if ($LASTEXITCODE -eq 0) {
    Write-Host "RAG layer disabled. No OpenSearch charges." -ForegroundColor Green
    Write-Host "Gold data preserved in S3. Re-run kb_enable.ps1 to restore RAG." -ForegroundColor Cyan
} else {
    Write-Host "Terraform apply failed" -ForegroundColor Red
    exit 1
}

Set-Location ../..
