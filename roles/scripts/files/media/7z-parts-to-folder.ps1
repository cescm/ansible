param(
    [string]$Path = "."
)

$files = Get-ChildItem -LiteralPath $Path -File | Where-Object { $_.Name -match '\.7z\.\d+$' }

if (-not $files) {
    Write-Host "No se encontraron archivos de partes .7z (.7z.001, .7z.002, ...) en '$Path'"
    exit 0
}

$groups = $files | Group-Object { ($_.Name -replace '\.7z\.\d+$', '') }
$total = 0

foreach ($group in $groups) {
    $targetDir = Join-Path $Path $group.Name
    [System.IO.Directory]::CreateDirectory($targetDir) | Out-Null
    foreach ($file in $group.Group) {
        try {
            Move-Item -LiteralPath $file.FullName -Destination $targetDir -ErrorAction Stop
            Write-Host "Movido: $($file.Name) -> $targetDir"
            $total++
        }
        catch {
            Write-Host "ERROR al mover '$($file.Name)': $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

Write-Host ""
Write-Host "Resumen: $total archivos movidos a $($groups.Count) carpetas."
