# Start the Glassbox backend. Pass a different model with: .\run.ps1 -Model tiny
param([string]$Model = "HuggingFaceTB/SmolVLM-256M-Instruct", [int]$Port = 8765)
Set-Location $PSScriptRoot
& .\.venv\Scripts\python.exe -m glassbox.server --model $Model --port $Port
