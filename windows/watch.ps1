# watch.ps1 - overvåger karakterfiler og sender hver ændring til audit-loggen på audit-serveren (Raspberry Pi)
#
# Kører i en løkke: hvert 5. sekund sammenlignes filernes SHA-256-hash med et snapshot.
# Ved en ændring bygges en JSON-hændelse (hvem, hvad, hvornår, hashes), som sendes over SSH.
# Er audit-serveren offline, lægges hændelsen i en kø og sendes, så snart den svarer igen.

# ── Opsætning ──────────────────────────────────────────────────────────────
$watchDir = "C:\UniData\karakterer"                    # mappen der overvåges
$stateDir = "C:\ProgramData\Karaktersag"               # scriptets tilstand: snapshot, kø, lokal log
$key      = "$env:USERPROFILE\.ssh\audit_ed25519"      # audit-nøgle (begrænset med command= og restrict på serveren)
$target   = "auditlog@karakter-pi"                     # modtager på audit-serveren

$snapDir = Join-Path $stateDir "snapshot"
$queue   = Join-Path $stateDir "queue.jsonl"
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)   # send UTF-8 (uden BOM) til ssh
New-Item -ItemType Directory -Path $snapDir -Force | Out-Null

# ── Send én hændelse ───────────────────────────────────────────────────────
# BatchMode=yes: stil aldrig spørgsmål (kører uden et menneske)
# ConnectTimeout=5: giv op efter 5 sekunder, så overvågningen ikke hænger
function Send-AuditEvent([string]$json) {
    $json | ssh -T -i $key -o BatchMode=yes -o ConnectTimeout=5 $target 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# ── Tøm køen ───────────────────────────────────────────────────────────────
# Prøver at sende køen igen og beholder kun de hændelser, der stadig fejler.
function Send-Queue {
    if (-not (Test-Path $queue)) { return }
    $left = @(Get-Content $queue | Where-Object { -not (Send-AuditEvent $_) })
    if ($left.Count -gt 0) { Set-Content $queue $left }
    else { Remove-Item $queue; Write-Host "Koe toemt - audit-serveren er online igen" -ForegroundColor Cyan }
}

# ── Hovedløkke ─────────────────────────────────────────────────────────────
Write-Host "Overvaager $watchDir (Ctrl+C stopper)"
while ($true) {
    Send-Queue                                          # gamle hændelser før nye
    foreach ($f in Get-ChildItem $watchDir -File) {
        $snap = Join-Path $snapDir $f.Name
        if (-not (Test-Path $snap)) { Copy-Item $f.FullName $snap; continue }   # første gang: baseline

        $oldHash = (Get-FileHash $snap -Algorithm SHA256).Hash
        $newHash = (Get-FileHash $f.FullName -Algorithm SHA256).Hash
        if ($oldHash -eq $newHash) { continue }         # uændret

        # Hashen siger AT filen er ændret - Compare-Object finder HVAD
        $diff  = Compare-Object (Get-Content $snap) (Get-Content $f.FullName)
        $entry = [ordered]@{
            tid         = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            bruger      = $env:USERNAME
            maskine     = $env:COMPUTERNAME
            handling    = "GRADE_FILE_MODIFIED"
            fil         = $f.Name
            gammel      = ($diff | Where-Object SideIndicator -eq "<=").InputObject -join "; "
            ny          = ($diff | Where-Object SideIndicator -eq "=>").InputObject -join "; "
            gammel_hash = $oldHash
            ny_hash     = $newHash
        }
        $json = $entry | ConvertTo-Json -Compress        # serialisering: objekt -> JSON på én linje

        Add-Content (Join-Path $stateDir "local.log") $json
        if (Send-AuditEvent $json) { Write-Host "SENDT til audit-serveren: $($f.Name)" -ForegroundColor Green }
        else { Add-Content $queue $json; Write-Warning "Audit-serveren svarer ikke - haendelsen er lagt i koe" }

        Copy-Item $f.FullName $snap -Force              # nyt snapshot
    }
    Start-Sleep -Seconds 5
}
