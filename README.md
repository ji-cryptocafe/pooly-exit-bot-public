# pooly-exit-bot

**🇩🇪 Deutsch · 🇬🇧 [English](README.en.md)**

> 💚 **Du möchtest mich unterstützen?** Erzähl anderen von meiner Krypto-Steuer-Software
> **[CryptoCafeTax](https://cryptocafetax.de)** — kostenlos testbar unter
> **[app.cryptocafetax.de](https://app.cryptocafetax.de)**. Dein Land fehlt bei der
> Steuer-Unterstützung? Melde dich, dann nehme ich es auf.

Ein kleiner Bot, der automatisch Geld rettet, das in einer **przUSDC**-Position
(PoolTogether V5 „Prize USDC – Moonwell") im Base-Netzwerk feststeckt.

Wenn dein „Withdraw"-Button nur noch fehlschlägt und dein Geld eingefroren wirkt,
ist das hier für dich.

---

## Was ist da los? (einfach erklärt)

Dein USDC liegt in einem Spar-Pool. Dieser Pool verleiht das Geld an einen
Kreditmarkt (Moonwell). Im Moment **haben fast alle geliehen und kaum jemand
zurückgezahlt** — deshalb ist kein Bargeld im Markt, um dich auszuzahlen. Genau
darum schlägt „Withdraw" fehl: Das Geld ist nicht weg, es ist nur *in diesem
Moment nicht verfügbar*.

Bargeld taucht kurz wieder auf, sobald **jemand einen Kredit zurückzahlt oder neues
Geld einzahlt** — verschwindet aber innerhalb von Sekunden wieder, weil auch andere
darauf warten.

**Dieser Bot beobachtet den Markt rund um die Uhr und schnappt sich deinen Anteil in
dem Augenblick, in dem Bargeld auftaucht** — schneller, als du es je von Hand
könntest. Er knabbert die Position Stück für Stück ab, bis sie komplett draußen ist.

---

## Ist mein Geld sicher? (ja — und hier ist warum)

Du gibst niemals dein Geld oder das Passwort deiner Haupt-Wallet aus der Hand.

- Du unterschreibst **eine einzige** Freigabe (Approval), ein einziges Mal, aus der
  Wallet, die das Geld hält.
- Diese Freigabe erlaubt einem winzigen, eigens dafür gebauten Contract, **nur deine
  feststeckende Position** zu bewegen — und **nur** an eine Adresse, die du selbst
  wählst (deine eigene Wallet oder eine Cold Wallet). Er kann dein Geld an keinen
  anderen Ort schicken, und daran lässt sich nach der Einrichtung nichts mehr ändern.
- Der Bot selbst läuft mit einem **separaten Wegwerf-Schlüssel**, der ausschließlich
  die Gas-Gebühren zahlt. Würde dieser Schlüssel morgen gestohlen, bekäme der Dieb
  nur ein paar Dollar übrig gebliebenes Gas — niemals deine Position.

Die vollständige Sicherheitsbegründung steht in **[TECHNICAL.md](TECHNICAL.md)**
(englisch).

---

## Was du brauchst

- Einen Computer (Mac, Windows oder Linux), den du laufen lassen kannst.
- Die Wallet (z. B. MetaMask), die das feststeckende przUSDC hält.
- Etwa **0,01 ETH im Base-Netzwerk** für Gas — ein paar Dollar.
- Einmalig 20–30 Minuten.

Du musst **kein** Programmierer sein. Die ausführliche Anleitung führt dich Befehl
für Befehl durch alles.

---

## So geht's — die Kurzfassung

Jeder Schritt verweist auf die genauen Befehle in **[DEPLOY.md](DEPLOY.md)**
(englisch). Folge dieser Anleitung von oben nach unten; diese Liste ist nur die
Übersicht.

1. **Hol den Code auf deinen Computer.**
   ```bash
   git clone https://github.com/ji-cryptocafe/pooly-exit-bot-public.git
   cd pooly-exit-bot-public
   npm install
   ```

2. **Erstelle einen Wegwerf-Schlüssel für Gas.** Ein Befehl (`./newkey.sh`) erzeugt
   einen brandneuen Schlüssel, der nur Gebühren zahlen kann. Deine echte Wallet ist
   nie beteiligt. → *DEPLOY Schritt 1*

3. **Trage die Einstellungen ein.** Kopiere `.env.example` nach `.env` und füge deine
   Wallet-Adresse und den Netzwerk-Endpunkt ein (ein funktionierender Standard ist
   bereits hinterlegt). → *DEPLOY Schritt 1*

4. **Schick ein paar Dollar ETH** (im Base-Netzwerk) an den Wegwerf-Schlüssel, damit
   er Gas zahlen kann. → *DEPLOY Schritt 2*

5. **Deploye den kleinen Rettungs-Contract** mit `./deploy.sh`. Er zeigt dir jeden
   Wert an und wartet, bis du `YES` tippst, bevor irgendetwas ausgegeben wird.
   → *DEPLOY Schritt 3*

6. **Prüfe alles doppelt und gib dann einmalig frei** — aus deiner echten Wallet, im
   Browser auf Basescan. Das ist das einzige Mal, dass deine Haupt-Wallet überhaupt
   etwas unterschreibt. → *DEPLOY Schritte 4–5*

7. **Starte den Bot** mit `npm run bot` und lass ihn laufen. Er meldet, was er tut,
   und **schaltet sich automatisch ab**, sobald deine Position vollständig gerettet
   ist. → *DEPLOY Schritt 6*

> Tipp: Führe zuerst `npm run watch` aus — ein sicherer „Trockenlauf", der zeigt, was
> der Bot tun *würde*, ohne eine Transaktion zu senden.

---

## Funktioniert es garantiert?

Es holt dein Geld heraus, **sobald der Markt Bargeld hat, um dich auszuzahlen** — und
ist dabei schneller als fast jeder, der es von Hand versucht. Aber sei realistisch:

- Wenn Kreditnehmer **nie** zurückzahlen, kommt kein Bargeld zurück, und kein Bot der
  Welt kann helfen. Das liegt in niemandes Hand.
- Andere lassen ähnliche Bots laufen. Du kannst etwas mehr für die Gas-Priorität
  ausgeben, um öfter zu gewinnen (siehe die Tuning-Hinweise in [DEPLOY.md](DEPLOY.md)).

Das ist ein Werkzeug, keine Finanzberatung. Lies nach, was es tut, prüfe den Contract,
bevor du ihn freigibst, und nutze es auf eigenes Risiko.

---

## Die drei Dokumente

| Datei | Wofür |
|---|---|
| **README** ([DE](README.md) · [EN](README.en.md)) | Was es ist und der Überblick. |
| **[DEPLOY.md](DEPLOY.md)** | Die genaue Schritt-für-Schritt-Anleitung (englisch). Hier anfangen, um es wirklich auszuführen. |
| **[TECHNICAL.md](TECHNICAL.md)** | Die technische Tiefe: Diagnose, Design und wie jede Behauptung getestet wurde (englisch). |
