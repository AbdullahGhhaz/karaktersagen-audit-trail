# Karaktersagen – et manipulationssikkert audit-spor på tværs af Windows og Linux

> **Kan vi bevise, hvem der ændrede en karakter – også hvis personen prøver at slette sine spor?**

Et eksamensprojekt fra PBA i IT-sikkerhed (2. semester, EK – fagene *Automatisering & Scripting* og *Datasikkerhed*, oktober 2026). Projektet bygger videre på en sikkerhedsrapport om et universitets studie- og karaktersystem og viser en af rapportens kontroller i praksis: et **audit trail**, som en insider ikke kan slette eller forfalske uden at blive opdaget.

*English summary: A PowerShell watcher on Windows detects changes to a grade file and ships each change as a JSON event over a restricted SSH key to a Raspberry Pi, where a Bash receiver validates it and appends it to an append-only, SHA-256 hash-chained log. A systemd timer re-verifies the chain every 5 minutes.*

---

## Demoen i fem trin

| # | Hvad sker der | Resultat |
|---|---|---|
| 1 | En insider ændrer en karakter fra **12 til 7** og sletter den lokale log | Den lokale log er væk |
| 2 | `watch.ps1` opdager ændringen inden for 5 sekunder | Hændelsen sendes krypteret over SSH |
| 3 | Beviset hentes på audit-serveren | **hvem, maskine, hvornår, 12 → 7** + filens hash før og efter |
| 4 | Insideren prøver at rette loggen – selv med `sudo` | `Operation not permitted` (append-only) |
| 5 | `audit-verify` genberegner hash-kæden | `OK – kæden er intakt` |

## Arkitektur

```
 WINDOWS (PowerShell)                                 RASPBERRY PI (Bash / systemd)
 ┌───────────────────────┐   JSON over SSH           ┌────────────────────────────┐
 │ watch.ps1             │   (audit-nøgle med         │ audit-receive              │
 │  hash hvert 5. sek.   │ ──command= + restrict)──► │  validering → flock →       │
 │  Compare-Object       │   via Tailscale            │  hash-kæde → append-only   │
 │  kø hvis offline      │                           │  /var/log/karakter/audit.log│
 └───────────────────────┘                           └─────────────┬──────────────┘
                                                                   │
                                                    audit-verify.timer (hvert 5. min)
                                                    genberegner kæden → journalctl
```

**Rød tråd:** opdage → pakke → sende → modtage → tjekke

## Filer

| Fil | Rolle |
|---|---|
| [`windows/watch.ps1`](windows/watch.ps1) | Overvåger karakterfilen. SHA-256 mod snapshot, `Compare-Object` finder den ændrede linje, hændelsen serialiseres til JSON og sendes med SSH. Offline-kø. |
| [`pi/audit-receive`](pi/audit-receive) | Modtager én JSON-linje på stdin, validerer den (fail closed), låser med `flock` og tilføjer den til hash-kæden. |
| [`pi/audit-verify`](pi/audit-verify) | Genberegner hele kæden og melder det første brud (`exit 1` + `auth.crit` i journalen). |
| [`pi/systemd/`](pi/systemd) | `audit-verify.service` (oneshot, kører som `auditlog`, ikke root) og `.timer` (hvert 5. minut). |
| [`pi/authorized_keys.example`](pi/authorized_keys.example) | Audit-nøglen er låst til én kommando. |
| [`docs/opsaetning.md`](docs/opsaetning.md) | Trin-for-trin opsætning. |

## Sikkerhedsvalg

| Valg | Hvorfor |
|---|---|
| **Separat audit-server** | Den, der logges, må ikke kunne slette sin egen log. Den lokale Windows-log er bevidst usikker – den er "loggen", audit-serveren er "audit trailet". |
| **Append-only** (`chattr +a`) | Loggen kan kun tilføjes til. `sed -i` og `rm` fejler – også med `sudo`. |
| **Hash-kæde** (SHA-256) | Hver linje indeholder hashen af den forrige. Én ændret linje bryder kæden og opdages af `audit-verify`. |
| **To SSH-nøgler** | Admin-nøglen har passphrase. Audit-nøglen har ingen (den skal køre automatisk), men er låst med `command=` og `restrict`: den kan **kun** aflevere hændelser. *Least privilege.* |
| **Inputvalidering** | Input fra netværket er upålideligt: tomt, > 4096 tegn, tabulator eller ikke-JSON afvises med `exit 2` og logges. |
| **`flock`** | Forhindrer, at to samtidige hændelser læser den samme forrige hash (race condition). |
| **Verify som `auditlog`** | systemd-servicen kører uprivilegeret, ikke som root. |
| **Tailscale (WireGuard)** | Ingen porte åbnet for SSH mod internettet. |
| **Offline-kø** | Et netværksudfald må ikke skabe huller i audit-sporet (tilgængelighed). |

## Kendte begrænsninger

Løsningen **opdager og beviser** – den **forhindrer** ikke ændringen. I et rigtigt system kombineres den med Segregation of Duties (en karakterændring skal godkendes af en anden).

- **Root på audit-serveren** kan fjerne `+a` og genberegne hele kæden. Modtræk: forankr den seneste hash et eksternt sted og giv audit-serveren andre administratorer end det overvågede system.
- **Sletning af den sidste linje** opdages ikke af kæden alene. Modtræk: ekstern forankring eller heartbeat.
- **En kompromitteret klient** kan sende falske hændelser. Kæden beviser kun integriteten *efter* modtagelse. Modtræk: korrelation med databasens egen audit (lagdelt audit).
- **Snapshot-princippet** opdager kun ændringer mellem to tjek (5 sek.) og overvåger én mappe.

## Hvad jeg lærte

- **CRLF:** Første gang Windows sendte en hændelse, blev den afvist – PowerShell sender `\r\n`, og valideringen krævede, at linjen sluttede med `}`. Valideringen gjorde det rigtige (*fail closed*); rettelsen var at fjerne `\r` i modtageren.
- **En tastefejl kan give falske alarmer:** `$g` i stedet for `$h` i verify-scriptet var gyldig Bash, men gav "BRUD" på en intakt kæde. `set -u` ville have fanget det.
- **Objekter vs. tekst:** `(Get-FileHash fil).Hash` i PowerShell mod `sha256sum fil | cut -d' ' -f1` i Bash.
- **Log ≠ audit trail:** Bash-historikken kan redigeres af brugeren selv og springer kommandoer med mellemrum foran over.

## Værktøjer og ærlighed

Projektet er udviklet med AI (Claude) som sparringspartner og værktøj. Bash-scriptsene er skrevet linje for linje med forklaring undervejs, PowerShell-scriptet er gennemgået blok for blok og testet, og fejlene ovenfor er fundet og rettet under test. Alt er kørt og testet på rigtig hardware (Windows 11 + Raspberry Pi 4 med Raspberry Pi OS).

## Teknologier

PowerShell 5.1 · Bash · systemd · OpenSSH (ed25519) · Tailscale · SHA-256 · `chattr` · `flock` · `jq` · Raspberry Pi 4
