# Opsætning

Forudsætninger: en Windows-maskine med OpenSSH-klient og en Linux-maskine (her Raspberry Pi 4 med Raspberry Pi OS Lite). Begge på samme netværk eller forbundet med f.eks. Tailscale.

## 1. Audit-serveren (Linux)

```bash
# Systembruger uden password til at modtage hændelser
sudo useradd --system --create-home --shell /bin/bash auditlog

# Logmappe: kun auditlog
sudo mkdir -p /var/log/karakter
sudo chown auditlog:auditlog /var/log/karakter
sudo chmod 750 /var/log/karakter
sudo -u auditlog touch /var/log/karakter/audit.log
sudo chmod 640 /var/log/karakter/audit.log
sudo chattr +a /var/log/karakter/audit.log        # append-only

# Scripts: ejes af root, så auditlog ikke kan ændre sin egen modtager
sudo install -o root -g root -m 755 pi/audit-receive /usr/local/bin/audit-receive
sudo install -o root -g root -m 755 pi/audit-verify  /usr/local/bin/audit-verify

# systemd-timer
sudo cp pi/systemd/audit-verify.service pi/systemd/audit-verify.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now audit-verify.timer
```

## 2. Audit-nøglen (Windows → Linux)

På Windows:
```powershell
ssh-keygen -t ed25519 -f $env:USERPROFILE\.ssh\audit_ed25519    # ingen passphrase
Get-Content $env:USERPROFILE\.ssh\audit_ed25519.pub
```

På Linux, i `/home/auditlog/.ssh/authorized_keys` (se `pi/authorized_keys.example`):
```bash
sudo mkdir -p /home/auditlog/.ssh
sudo nano /home/auditlog/.ssh/authorized_keys
sudo chown -R auditlog:auditlog /home/auditlog/.ssh
sudo chmod 700 /home/auditlog/.ssh
sudo chmod 600 /home/auditlog/.ssh/authorized_keys
```

Test fra Windows (første gang skal værtsnøglen accepteres):
```powershell
'{"test":"hej"}' | ssh -T -i $env:USERPROFILE\.ssh\audit_ed25519 auditlog@karakter-pi
# → OK <hash>
```

## 3. Overvågningen (Windows)

```powershell
New-Item -ItemType Directory -Path C:\UniData\karakterer, C:\Scripts -Force | Out-Null
Copy-Item windows\watch.ps1 C:\Scripts\
powershell -ExecutionPolicy Bypass -File C:\Scripts\watch.ps1
```

## 4. Test

```bash
sudo tail -n 1 /var/log/karakter/audit.log | cut -f5 | jq .      # seneste hændelse
sudo sed -i 's/,7"/,12"/' /var/log/karakter/audit.log             # → Operation not permitted
sudo audit-verify                                                 # → OK: n hændelser
systemctl list-timers | grep audit
journalctl -t audit-receive -t audit-verify -n 10
```

Manipulationstest på en kopi:
```bash
sudo cp /var/log/karakter/audit.log /tmp/kopi.log
sudo sed -i '1s/a/b/' /tmp/kopi.log
sudo audit-verify /tmp/kopi.log      # → BRUD i kæden ved linje 1
```
