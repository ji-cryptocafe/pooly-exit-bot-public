# Deployment — für alle, die noch nie etwas deployt haben

**🇩🇪 Deutsch · 🇬🇧 [English](DEPLOY.en.md)**

**Auf deinem sicheren Rechner wird nichts installiert.** Er öffnet nur einen Browser und
klickt einen einzigen Knopf. Alles andere läuft auf dem Entwickler-Rechner mit einem
Wegwerf-Schlüssel, der deine Position niemals berühren kann.

| Rechner | Rolle | Was installiert sein muss |
|---|---|---|
| **Sicherer Rechner** (hält `0xYOUR_WALLET`) | Unterschreibt genau EINE Transaktion, ein einziges Mal: das `approve`. | Nichts. Ein Browser + deine Wallet-Erweiterung. |
| **Entwickler-Rechner** (dieses Repo) | Deployt den Contract, betreibt den Bot. | Bereits eingerichtet. |
| **Wegwerf-Schlüssel** (unten erstellt) | Zahlt das Gas für Deployment und Bot. | — |

Der Wegwerf-Schlüssel ist *nur* ein Gas-Zahler. Er wird im Contract nirgends genannt, und der
Contract kann Geld ausschließlich an den unveränderlichen `RECEIVER` senden. Würde er morgen
gestohlen, bekäme der Angreifer nur das restliche ETH darauf und sonst nichts.

---

## Kosten (gemessen, Base bei 0,005 gwei)

| | Gas | Kosten bei 4000 $/ETH |
|---|---|---|
| Contract deployen | 557.372 | **0,011 $** |
| dein `approve` | ~46.000 | **0,001 $** |
| jeder erfolgreiche Grab | ~900.000 | **0,018 $** |
| jeder fehlgeschlagene Versuch | ~158.000 | **0,003 $** |

Plane ~0,003 ETH auf dem Wegwerf-Schlüssel ein. Das reicht für über tausend Versuche.

---

## Schritt 1 — Wegwerf-Schlüssel erstellen (Entwickler-Rechner)

**Nutze dafür nicht MetaMask.** Der Bot braucht einen rohen Private Key in einer
Klartext-Datei, und jedes MetaMask-Konto wird aus deiner Seed Phrase abgeleitet. Ein Export
verrät zwar nicht die Seed, legt aber grundlos einen Schlüssel aus deiner Haupt-Wallet-Familie
in eine „heiße" Datei. Der folgende Befehl erzeugt stattdessen einen mathematisch unabhängigen
Schlüssel:

```bash
cd pooly-exit-bot-public
./newkey.sh
```

Er schreibt den Schlüssel direkt in `.env` (chmod 600) und gibt **nur die Adresse** aus. Der
Private Key wird nie angezeigt, landet also nicht in deinem Terminal-Verlauf oder irgendeinem
Transkript. Führe **nicht** einfach `cast wallet new` aus — das druckt den Schlüssel auf den
Bildschirm.

Derselbe Schlüssel wird für Deployment und Bot verwendet; beide Aufgaben sind nur „Gas zahlen".

Öffne dann `.env` und trage den Rest ein:

```
BASE_RPC_URL=https://mainnet.base.org
OWNER_ADDRESS=0xYOUR_WALLET_ADDRESS
RECEIVER_ADDRESS=0xYOUR_WALLET_ADDRESS
MIN_RATE_BPS=9999
```

(`DEPLOYER_PRIVATE_KEY` / `BOT_PRIVATE_KEY` unangetastet lassen — `newkey.sh` hat sie bereits
gesetzt.)

### Was dieser Schlüssel kann und was nicht

- **Kann:** Gas zahlen, den Contract deployen, `grab()` aufrufen.
- **Kann nicht:** dein przUSDC berühren, das USDC umleiten oder irgendetwas am Contract ändern.
  Er wird im Contract nirgends genannt. Würde er morgen gestohlen, bekäme der Angreifer nur das
  restliche Gas-Geld und sonst nichts.

MetaMask ist im gesamten Ablauf nur an Schritt 2 (Gas senden) und Schritt 5 (das Approve)
beteiligt.

### RECEIVER wählen — das ist unveränderlich, mach es richtig

- **Gleich wie OWNER** (`0xYOUR_WALLET`): Das zurückgeholte USDC landet einfach wieder in der
  Wallet, aus der es kam. Am einfachsten, nichts Neues zu verwalten.
- **Eine Hardware-Wallet**: besser, falls du `0xYOUR_WALLET` überhaupt als exponiert
  betrachtest.

Nach dem Deployment lässt es sich nicht mehr ändern. Eine Änderung bedeutet: erneut deployen
und erneut freigeben.

## Schritt 2 — Wegwerf-Schlüssel auffüllen (sicherer Rechner, Browser)

Sende in MetaMask **0,003 ETH** an die Adresse, die `newkey.sh` ausgegeben hat.
Achte darauf, dass das Netzwerk **Base** ist, nicht Ethereum Mainnet.

## Schritt 3 — deployen (Entwickler-Rechner)

```bash
./deploy.sh
```

Es zeigt dir jeden Wert an, simuliert ohne etwas auszugeben, wartet, bis du `YES` tippst,
deployt und verifiziert dann den Quellcode auf Basescan, damit du ihn im Browser lesen kannst.
Am Ende gibt es deine Contract-Adresse und die genauen Anweisungen für Schritt 4 aus.

## Schritt 4 — prüfen, bevor du ihm vertraust (sicherer Rechner, Browser)

Öffne `https://basescan.org/address/<DEIN_EXITOR>#readContract` und bestätige **alle fünf**:

```
VAULT        = 0x7f5C2b379b88499aC2B997Db583f8079503f25b9
ASSET        = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
OWNER        = 0xYOUR_WALLET_ADDRESS
RECEIVER     = <was du gewählt hast>
MIN_RATE_BPS = 9999
```

**Weicht ein Wert ab, halte an. Nicht freigeben.** Das ist die gesamte Sicherheitsprüfung —
sobald diese fünf stimmen, kann der Contract dein Geld nachweislich an keinen anderen Ort
senden.

## Schritt 5 — freigeben (sicherer Rechner, Browser)

Gehe zu:

```
https://basescan.org/address/0x7f5C2b379b88499aC2B997Db583f8079503f25b9#writeContract
```

- Klicke **Connect to Web3** und verbinde `0xYOUR_WALLET`.
- Suche **approve** und gib ein:
  - `spender` = deine Exitor-Adresse
  - `amount` = `<dein genauer przUSDC-Kontostand, ohne Dezimalpunkt geschrieben>`
- Klicke **Write** und bestätige in deiner Wallet.

przUSDC hat 6 Nachkommastellen, lass also den Dezimalpunkt weg: Ein Kontostand, der als
`1000.000000 przUSDC` angezeigt wird, wird als `1000000000` eingegeben. Deinen genauen
Kontostand liest du aus deiner Wallet oder auf Basescan ab.
**Genau diesen Betrag freigeben, nicht unbegrenzt.** Mehr braucht der Bot nie, und es begrenzt
den möglichen Schaden auf genau die Position, die du ohnehin retten willst.

Zum späteren Widerrufen: dasselbe noch einmal mit `amount = 0`.

## Schritt 6 — Bot starten (Entwickler-Rechner)

```bash
npm run watch    # Trockenlauf: meldet, was er tun würde, sendet nichts
```

Prüfe, dass `allowance ✅ set` und `vault … ✅ verified` erscheinen. Dann:

```bash
npm run bot
```

Lass ihn laufen. Er beendet sich von selbst, sobald die Position bei null ist.

Um ihn nach dem Schließen des Terminals am Leben zu halten:

```bash
nohup npm run bot > bot.log 2>&1 &
tail -f bot.log
```

Stoppen mit `pkill -f exit-bot`.

---

## Was du sehen wirst

Leerlauf (der Normalzustand — kann Tage dauern):

```
[12:00:00] mUSDC cash 0.000001 USDC | available 0.00 USDC
[12:00:00] polling every 500ms -- waiting for liquidity...
```

Wenn Liquidität auftaucht:

```
[14:23:11] LIQUIDITY: available 800.00 USDC | mUSDC cash 800.000001 USDC -> firing
[14:23:11] ✅ GRABBED 800.00 USDC | total recovered 800.00 USDC | shares left <remaining> USDC
```

`reverted (no liquidity by inclusion time)` heißt, jemand war schneller. Kostet ~0,003 $.
Wenn du das wiederholt siehst, erhöhe `PRIORITY_GWEI` in `.env` und starte neu.

---

## Wann feuert er eigentlich?

Zwei Tore, beide müssen passieren. Es gibt **keine Obergrenze** — er nimmt immer alles
Verfügbare, begrenzt nur durch deine verbleibende Position.

1. **`MIN_ASSETS_USDC`** (Standard `5`) — eine harte Untergrenze in Dollar.
2. **`MAX_GAS_PCT`** (Standard `2`) — das Gas muss unter 2 % dessen bleiben, was der Grab
   einbringt. Dieses Tor zählt, falls die Base-Gebühren je in die Höhe schießen; die feste
   Untergrenze allein würde dann still ihren Sinn verlieren.

Worst-Case-Gas, um eine **1.000-$-Position** vollständig herauszuholen, wenn *jede* Teilzahlung
genau diese Größe hätte. Es skaliert linear — verdopple die Position, und du verdoppelst Grabs
und Gesamt-Gas, aber der **%-Anteil an der Position bleibt gleich**:

| Ø Teilzahlung | Grabs (pro 1.000 $) | Gesamt-Gas (pro 1.000 $) | % der Position |
|---|---|---|---|
| 1 $ | 1000 | 18,00 $ | 1,80 % |
| 5 $ | 200 | 3,60 $ | 0,36 % |
| 10 $ | 100 | 1,80 $ | 0,18 % |
| 25 $ | 40 | 0,72 $ | 0,07 % |
| 100 $ | 10 | 0,18 $ | 0,02 % |

`5` ist ein guter Standard. Die Untergrenze anzuheben bringt dir **keine** größeren
Teilzahlungen — es bedeutet nur, dass kleine an jemand anderen gehen; und bei ~13,16 Mio. USDC
an konkurrierenden Ansprüchen sind gerade die kleinen Teilzahlungen die, die du am ehesten
tatsächlich gewinnst. Senke sie auf `1`, wenn du lieber 1,8 % an Gas abarbeitest, als das
Risiko einzugehen, gar nicht herauszukommen.

---

## Wenn etwas schiefgeht

| Symptom | Lösung |
|---|---|
| `allowance ❌ ZERO` | Schritt 5 kam nicht durch. Prüfe die Tx auf Basescan. |
| `refusing to run` beim Start | On-Chain-VAULT/ASSET passen nicht. **Nicht** freigeben. Neu deployen. |
| `insufficient funds` | Der Wegwerf-Schlüssel hat kein ETH mehr. Schick ihm mehr. |
| Wiederholte Reverts | Jemand ist schneller. Erhöhe `PRIORITY_GWEI` in `.env` und starte neu. |
| Alles stoppen | `pkill -f exit-bot`, dann `approve(exitor, 0)` auf Basescan. |
