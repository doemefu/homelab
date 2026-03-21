# Ubuntu Server auf Intel MacBook Air mit T2-Chip: Vollständige Installationsanleitung

Beide MacBook-Air-Modelle (2020 und 2019) werden vom t2linux-Projekt vollständig unterstützt und eignen sich als Linux-Serverknoten — allerdings erfordert die Installation deutlich mehr Schritte als auf Standard-Hardware. Diese Anleitung führt von der laufenden macOS-Installation bis zum funktionierenden Ubuntu-Server im k3s-Cluster. **Es existiert kein fertiges Ubuntu-Server-ISO mit T2-Unterstützung**; der empfohlene Weg ist die Installation des offiziellen Ubuntu Server 24.04 LTS mit anschließender Einrichtung des t2linux-Kernels. Das t2linux-Projekt ist aktiv gepflegt (letzter Kernel-Release: **v6.19.4** vom 27. Februar 2026) und liefert alle nötigen Treiber über ein eigenes APT-Repository.

---

## 1. Hardwareübersicht und Voraussetzungen

### Die beiden Maschinen im Detail

| Eigenschaft | Maschine 1 (2020) | Maschine 2 (2019) |
|---|---|---|
| Modell-ID | MacBookAir9,1 | MacBookAir8,1 |
| CPU | Intel Core i5-1030NG7, 4 Kerne, 1,1 GHz | Intel Core i5-8210Y, 2 Kerne, 1,6 GHz |
| GPU | Intel Iris Plus (Ice Lake) | Intel UHD 617 |
| RAM | 8 GB LPDDR4X | 8 GB LPDDR3 |
| Wi-Fi-Chip | Broadcom **BCM4377** | Broadcom **BCM4355** |
| Kühlung | Lüfter vorhanden, aber **kein Heatpipe zur CPU** | Lüfter mit Heatpipe |
| macOS | Sequoia 15.1.1 | Sonoma 14.7.5 |
| Anschlüsse | 2× USB-C/Thunderbolt 3 | 2× USB-C/Thunderbolt 3 |

**Wichtiger Hinweis zur Kühlung:** Das 2020er-Modell hat ein bekanntes Designproblem — der Lüfter ist **nicht über ein Heatpipe** mit dem CPU-Heatsink verbunden. Unter Dauerlast throttelt die CPU deutlich stärker als beim 2019er-Modell. Für leichte Serverlast (k3s-Agent, unter 10 % CPU-Auslastung) ist dies akzeptabel, aber bei rechenintensiven Workloads problematisch.

### Benötigte Hardware für die Installation

- **USB-C-auf-USB-A-Adapter** (oder USB-C-Hub) — für USB-Stick und externe Peripherie
- **USB-Stick** (mindestens 4 GB, USB 3.0 empfohlen)
- **Externe USB-Tastatur** — die interne Tastatur funktioniert erst nach Installation des apple-bce-Treibers
- **USB-C-auf-Ethernet-Adapter** (Chipsatz Realtek RTL8153 empfohlen) — für Netzwerk während und nach der Installation
- Optional: externe USB-Maus (hilfreich, aber nicht zwingend im Server-Installer)

### Treiberübersicht: Was funktioniert unter Linux

| Komponente | Status | Treiber | Anmerkung |
|---|---|---|---|
| Internes NVMe-SSD | ✅ Funktioniert | Mainline-Kernel (seit 5.4) | T2-Hardwareverschlüsselung transparent |
| Display | ✅ Funktioniert | i915 (Mainline) | 2560×1600, volle Auflösung |
| Tastatur | ✅ Funktioniert | apple-bce (t2linux) | Nicht im Mainline-Kernel |
| Trackpad | ✅ Funktioniert | apple-bce (t2linux) | Kein Force Touch, keine Handballenerkennung |
| Wi-Fi | ✅ Funktioniert | brcmfmac (Mainline + Firmware) | Firmware muss aus macOS extrahiert werden |
| Bluetooth | ⚠️ Teilweise | hci_bcm4377 | BCM4377 (2020): Probleme bei 2,4-GHz-WLAN |
| Audio | ⚠️ Teilweise | apple-bce | Lautsprecher funktionieren, Qualität mäßig |
| Lüfter | ✅ Funktioniert | t2fanrd | Zusätzlicher Daemon empfohlen |
| Touch ID | ❌ Nicht möglich | — | Secure Enclave ohne Linux-Treiber |
| Kamera | ✅ Funktioniert | apple-bce → UVC | Für Server irrelevant |

---

## 2. Vorbereitungen noch unter macOS (vor der Löschung)

Dieser Abschnitt ist **kritisch** — einige Schritte müssen zwingend vor dem Entfernen von macOS erfolgen. Die Reihenfolge ist wichtig.

### 2.1 Wi-Fi-Firmware aus macOS extrahieren

Die Broadcom-Wi-Fi-Firmware unterliegt Apples Lizenz und kann nicht frei verteilt werden. Ohne diese Dateien funktioniert das interne WLAN unter Linux nicht. **Die Firmware muss vor dem Löschen von macOS gesichert werden**, falls kein kabelgebundenes Netzwerk zur Verfügung steht.

**Methode A: Firmware auf den USB-Stick kopieren (empfohlen)**

Das t2linux-Projekt stellt ein Skript bereit. Im macOS-Terminal:

```bash
# Skript herunterladen
curl -sL https://wiki.t2linux.org/tools/firmware.sh -o firmware.sh
chmod +x firmware.sh

# Methode 2: Tarball erstellen
bash firmware.sh
```

Das Skript bietet mehrere Optionen. Für die spätere Verwendung auf dem USB-Stick eignet sich die Tarball-Methode: Die erzeugte Datei `firmware.tar.gz` auf den USB-Stick kopieren und nach der Linux-Installation nach `/lib/firmware/brcm/` extrahieren.

**Methode B: Alternativ ohne macOS (nach dem Löschen)**

Steht nach der Installation kabelgebundenes Netzwerk zur Verfügung (USB-Ethernet-Adapter), kann die Firmware auch nachträglich heruntergeladen werden:

```bash
# Auf dem installierten Ubuntu Server mit Netzwerkverbindung:
sudo apt install -y apple-t2-audio-config
sudo get-apple-firmware get_from_online
```

Dieser Befehl lädt ein macOS-Recovery-Image von Apple herunter und extrahiert die Firmware daraus. Dafür ist eine Internetverbindung über Ethernet oder externen USB-WLAN-Adapter nötig.

**Fehlerbehebung:**
- *Skript lädt keine Firmware herunter:* Sicherstellen, dass `curl` und `cpio` installiert sind
- *Firmware-Dateien am falschen Ort:* Die Dateien müssen exakt in `/lib/firmware/brcm/` liegen; der Dateiname muss zum Chip passen (z. B. `brcmfmac4377b3-pcie.bin` für das 2020er-Modell)

### 2.2 Automatischen Neustart nach Stromausfall aktivieren

Für einen 24/7-Server ist es wichtig, dass die Maschine nach einem Stromausfall automatisch hochfährt. Diese Einstellung wird im NVRAM gespeichert und bleibt auch nach dem Löschen von macOS bestehen.

```bash
# Im macOS-Terminal:
sudo pmset -a autorestart 1
```

### 2.3 Bootbares macOS-USB-Installationsmedium erstellen (optional, empfohlen)

Falls die Linux-Installation fehlschlägt oder macOS-Updates für T2-Firmware nötig werden, ist ein macOS-Recovery-Stick hilfreich. Alternativ funktioniert auch Internet Recovery (Cmd+Option+R beim Start), ist aber langsam.

### 2.4 USB-Installationsmedium für Ubuntu Server erstellen

**Auf macOS:**

```bash
# Ubuntu Server 24.04 LTS ISO herunterladen (von ubuntu.com)
# USB-Stick identifizieren:
diskutil list
# Beispiel: /dev/disk2 (externer USB-Stick)

# USB-Stick unmounten:
sudo diskutil unmountDisk /dev/disk2

# ISO auf USB-Stick schreiben (rdisk für schnelleren Zugriff):
sudo dd if=~/Downloads/ubuntu-24.04-live-server-amd64.iso of=/dev/rdisk2 bs=1m status=progress

# Fortschritt prüfen: Ctrl+T drücken
```

**Hinweis:** `/dev/rdisk2` (mit `r`-Prefix) ist auf macOS deutlich schneller als `/dev/disk2`.

**Fehlerbehebung:**
- *„Resource busy":* Alle Partitionen des USB-Sticks müssen unmountet sein (`diskutil unmountDisk`, nicht `diskutil eject`)
- *Boot-Stick wird nicht erkannt:* USB-Stick im FAT32-Format oder ISO-Hybrid-Format prüfen; balenaEtcher als Alternative verwenden

---

## 3. T2-Chip: Startup Security Utility konfigurieren

Der T2-Sicherheitschip blockiert standardmäßig das Booten von externen Medien und unsignierten Betriebssystemen. **Zwei Einstellungen müssen geändert werden.**

### Zugang zur Startup Security Utility

1. Mac **vollständig herunterfahren** (Apfel → Ausschalten)
2. Einschalttaste drücken und **sofort Cmd (⌘) + R gedrückt halten**
3. Warten, bis das Apple-Logo oder ein Fortschrittsbalken erscheint
4. In macOS Recovery den **Benutzer-Account** auswählen und **Administratorpasswort** eingeben
5. In der Menüleiste: **Dienstprogramme → Startsicherheitsdienstprogramm** (Utilities → Startup Security Utility)
6. Erneut Administratorpasswort eingeben

### Einstellungen ändern

**Sichere Starteinstellungen (Secure Boot) → „Ohne Sicherheit" (No Security)**

Die Standardeinstellung „Volle Sicherheit" prüft, ob das Betriebssystem speziell für diesen Mac signiert ist — Linux besteht diese Prüfung nicht. Auch „Mittlere Sicherheit" reicht nicht aus, da Apples Secure-Boot-Implementation weder shim-signed GRUB noch andere Linux-Bootloader-Signaturen akzeptiert. **Nur „Ohne Sicherheit" erlaubt das Booten von Linux.**

**Externes Starten → „Starten von externen Medien erlauben" (Allow booting from external media)**

Diese Einstellung ist **unabhängig** von Secure Boot. Selbst bei deaktiviertem Secure Boot weigert sich der Mac, von USB zu starten, wenn diese Option nicht aktiviert ist.

**Fehlerbehebung:**
- *„Für die Verwendung dieses Startvolumes ist ein Softwareupdate erforderlich":* Secure Boot steht noch auf „Volle" oder „Mittlere Sicherheit" → zurück in Recovery und auf „Ohne Sicherheit" setzen
- *USB-Stick erscheint nicht im Startup Manager:* Externes Booten ist noch deaktiviert → in Recovery aktivieren
- *Die Einstellungen sind identisch auf macOS Sequoia und Sonoma* — kein Unterschied zwischen den beiden Maschinen

---

## 4. Ubuntu Server installieren

### 4.1 Vom USB-Stick starten

1. USB-Stick, USB-Ethernet-Adapter und externe Tastatur anschließen
2. Mac **neustarten** und sofort die **Option-Taste (⌥)** gedrückt halten
3. Im Startup Manager erscheint ein oranges **„EFI Boot"**-Symbol — dieses auswählen
4. Enter drücken → der GRUB-Bootloader des Installers erscheint

**Wichtig:** Falls die Installation hängt oder der GRUB-Installer fehlschlägt, den Kernel-Parameter `efi=noruntime` hinzufügen:
- Im GRUB-Menü `e` drücken (auf externer Tastatur)
- In der Zeile mit `linux` am Ende `efi=noruntime` ergänzen
- Mit `F10` booten (Ctrl+X funktioniert möglicherweise nicht auf Mac-Tastaturen)

### 4.2 Installation mit manueller Partitionierung

Die interne Tastatur und das Trackpad funktionieren im Installer **nicht** (der apple-bce-Treiber ist nicht im Standard-Kernel enthalten). Die externe USB-Tastatur ist zwingend erforderlich.

**Partitionslayout für die vollständige macOS-Ersetzung:**

| Partition | Mountpoint | Größe | Dateisystem | Aktion |
|---|---|---|---|---|
| /dev/nvme0n1p1 | /boot/efi | ~300 MB | FAT32 (EFI) | **Behalten, nicht formatieren** |
| /dev/nvme0n1p2 | / | Restlicher Speicher minus Swap | ext4 | Neu erstellen |
| /dev/nvme0n1p3 | [swap] | 2–4 GB | Linux Swap | Neu erstellen (optional) |

**Schritt-für-Schritt im Ubuntu-Server-Installer:**

1. Sprache und Tastaturlayout wählen (Deutsch oder Englisch)
2. Netzwerk: Der USB-Ethernet-Adapter sollte automatisch erkannt werden und per DHCP eine IP beziehen. Falls nicht, manuell konfigurieren.
3. Bei der Festplattenkonfiguration **„Custom storage layout"** (Benutzerdefiniert) wählen
4. Alle macOS-Partitionen **löschen** (APFS-Container, Recovery etc.) — **aber /dev/nvme0n1p1 (EFI-Partition) behalten**
5. Die EFI-Partition (`/dev/nvme0n1p1`, ~300 MB, FAT32) als **EFI System Partition** markieren, Mountpoint `/boot/efi`, **nicht formatieren**
6. Neue Partition für `/` erstellen (ext4, restlicher Speicher)
7. Optional: Swap-Partition erstellen (2–4 GB) oder später eine Swap-Datei anlegen
8. Installation starten

**Fehlerbehebung:**
- *GRUB-Installation schlägt fehl / System hängt:* Neustart mit `efi=noruntime`-Kernel-Parameter. Alternativ GRUB manuell nach der Installation einrichten.
- *„Force UEFI Installation?" — Warnung:* Bestätigen, T2-Macs booten ausschließlich im UEFI-Modus
- *NVMe-SSD wird nicht erkannt:* Sehr selten bei Kernel 5.4+, aber falls vorhanden: auf fehlenden NVMe-Treiber im Installer prüfen

### 4.3 GRUB auf T2-Macs: Bekannte Probleme und Lösungen

Der T2-Chip hat **strikte NVRAM-Einschränkungen**. Schreibzugriffe auf EFI-Variablen können Kernel-Panics verursachen. Falls die automatische GRUB-Installation fehlschlägt, manuell installieren:

```bash
# In eine chroot-Umgebung wechseln (falls nötig nach fehlgeschlagener Installation):
sudo mount /dev/nvme0n1p2 /mnt
sudo mount /dev/nvme0n1p1 /mnt/boot/efi
sudo chroot /mnt

# GRUB manuell installieren mit T2-spezifischen Flags:
grub-install --target=x86_64-efi --efi-directory=/boot/efi \
  --bootloader-id=GRUB --no-nvram --removable
update-grub
```

Die Flags `--no-nvram` (verhindert NVRAM-Schreibzugriffe) und `--removable` (installiert GRUB als `EFI/BOOT/BOOTX64.EFI`, wird von der Mac-Firmware automatisch gefunden) sind entscheidend.

**NVRAM nach der Installation schreibschützen** — verhindert zukünftige Kernel-Panics durch versehentliche EFI-Variablen-Schreibzugriffe:

```bash
echo "efivarfs /sys/firmware/efi/efivars efivarfs ro,remount,nofail 0 0" | sudo tee -a /etc/fstab
```

### 4.4 rEFInd als empfohlene Alternative zu GRUB

Die t2linux-Community empfiehlt **rEFInd** als Boot-Manager, da Ubuntus GRUB auf T2-Macs häufig Probleme mit dem Startup Manager verursacht (schwarzer Bildschirm, langsamer Start).

```bash
# rEFInd installieren (nach der Ubuntu-Installation):
sudo apt install refind

# Konfiguration anpassen:
sudo nano /boot/efi/EFI/refind/refind.conf
# Folgende Zeile hinzufügen/ändern:
# use_nvram false
```

**Kritisch:** `use_nvram false` muss gesetzt sein — der T2-Chip reagiert empfindlich auf NVRAM-Schreibzugriffe.

---

## 5. T2-Kernel und Treiber einrichten

Nach der Basisinstallation fehlen die T2-spezifischen Treiber. Die interne Tastatur, das Trackpad und WLAN funktionieren noch nicht. Alle folgenden Schritte erfordern eine **externe Tastatur** und eine **kabelgebundene Netzwerkverbindung** (USB-Ethernet).

### 5.1 t2linux APT-Repository hinzufügen

```bash
# Codename der Ubuntu-Version (für 24.04 LTS):
CODENAME=noble

# GPG-Schlüssel importieren:
curl -s --compressed "https://adityagarg8.github.io/t2-ubuntu-repo/KEY.gpg" \
  | gpg --dearmor \
  | sudo tee /etc/apt/trusted.gpg.d/t2-ubuntu-repo.gpg > /dev/null

# Repository hinzufügen:
sudo curl -s --compressed \
  -o /etc/apt/sources.list.d/t2.list \
  "https://adityagarg8.github.io/t2-ubuntu-repo/t2.list"

echo "deb [signed-by=/etc/apt/trusted.gpg.d/t2-ubuntu-repo.gpg] https://github.com/AdityaGarg8/t2-ubuntu-repo/releases/download/${CODENAME} ./" \
  | sudo tee -a /etc/apt/sources.list.d/t2.list

sudo apt update
```

### 5.2 T2-Kernel installieren

Zwei Varianten stehen zur Verfügung:

```bash
# Variante 1: Mainline-Kernel (aktuellste Funktionen, z.B. 6.19.x)
sudo apt install linux-t2

# Variante 2: LTS-Kernel (stabiler, z.B. 6.12.x)
sudo apt install linux-t2-lts
```

**Empfehlung für Server:** Der **LTS-Kernel** (`linux-t2-lts`) bietet mehr Stabilität und ist für einen Serverknoten die bessere Wahl.

### 5.3 Kernel-Parameter konfigurieren

```bash
sudo nano /etc/default/grub

# Folgende Zeile anpassen:
GRUB_CMDLINE_LINUX_DEFAULT="intel_iommu=on iommu=pt pcie_ports=compat"

# GRUB-Menü sichtbar machen (wichtig für Fehlerbehebung):
GRUB_TIMEOUT=5
GRUB_TIMEOUT_STYLE=menu

# Änderungen übernehmen:
sudo update-grub
```

Die Parameter `intel_iommu=on iommu=pt pcie_ports=compat` sind **zwingend erforderlich** für Tastatur, Trackpad, Audio und Thunderbolt-Funktionalität.

### 5.4 apple-bce-Modul beim Start laden

```bash
echo "apple-bce" | sudo tee /etc/modules-load.d/t2.conf
```

Dieses Modul stellt die Verbindung zum T2-Chip her und macht Tastatur, Trackpad und Kamera als virtuelle USB-Geräte verfügbar.

### 5.5 Neustart und Verifizierung

```bash
sudo reboot

# Nach dem Neustart prüfen:
uname -r  # Sollte eine t2-Kernel-Version anzeigen (z.B. 6.12.76-t2-lts)
lsmod | grep apple_bce  # apple-bce muss geladen sein
```

**Fehlerbehebung:**
- *System bootet nicht mit neuem Kernel:* Im GRUB-Menü den alten Standard-Kernel auswählen (unter „Advanced options"), dann Kernel-Parameter prüfen
- *apple-bce lädt nicht:* Prüfen, ob `/etc/modules-load.d/t2.conf` korrekt ist; `dmesg | grep -i bce` für Fehlermeldungen
- *Tastatur/Trackpad funktionieren nach Neustart nicht:* `sudo modprobe apple-bce` manuell ausführen; falls Fehler auftreten, Kernel-Parameter `intel_iommu=on iommu=pt pcie_ports=compat` prüfen

---

## 6. Wi-Fi- und Bluetooth-Firmware einrichten

### 6.1 Firmware installieren

**Falls die Firmware vor dem Löschen von macOS gesichert wurde (Tarball):**

```bash
# USB-Stick mounten:
sudo mount /dev/sda1 /mnt/usb  # Pfad anpassen

# Firmware extrahieren:
sudo tar xf /mnt/usb/firmware.tar.gz -C /lib/firmware/brcm/

# Treibermodul neu laden:
sudo modprobe -r brcmfmac_wcc && sudo modprobe -r brcmfmac && sudo modprobe brcmfmac
```

**Falls macOS bereits gelöscht wurde (Online-Methode über Ethernet):**

```bash
sudo get-apple-firmware get_from_online
```

Dieser Befehl lädt ein macOS-Recovery-Image (~600 MB) herunter und extrahiert die Wi-Fi-Firmware automatisch.

### 6.2 Wi-Fi-Verbindung testen

```bash
# Verfügbare Schnittstellen anzeigen:
ip link show

# WLAN-Netzwerke scannen:
sudo iwlist wlan0 scan | grep ESSID

# Verbindung herstellen (mit netplan für Ubuntu Server):
sudo nano /etc/netplan/01-wifi.yaml
```

```yaml
network:
  version: 2
  renderer: networkd
  wifis:
    wlan0:
      dhcp4: true
      access-points:
        "MeinNetzwerk":
          password: "MeinPasswort"
```

```bash
sudo netplan apply
```

### 6.3 Chipspezifische Besonderheiten

**MacBook Air 2020 (BCM4377):** Bluetooth hat ein bekanntes Problem — bei Verbindung mit einem 2,4-GHz-WLAN treten Bluetooth-Störungen auf. **Workaround:** Ausschließlich 5-GHz-WLAN verwenden oder Bluetooth deaktivieren, wenn nicht benötigt.

**MacBook Air 2019 (BCM4355):** Weniger Probleme, Bluetooth funktioniert zuverlässiger.

**Fehlerbehebung:**
- *„Direct firmware load failed with error -2" in dmesg:* Das ist **normal** — der Treiber probiert mehrere Firmware-Dateinamen durch, bevor er den richtigen findet
- *WLAN verbindet sich nicht:* `wpa_supplicant` 2.11 hat eine Regression bei Broadcom-Chips. Lösung: `iwd` als Backend verwenden oder Kernel-Parameter `brcmfmac.feature_disable=0x82000` hinzufügen
- *WLAN fällt nach Suspend/Resume aus:* Für einen Server irrelevant (Suspend wird deaktiviert), aber lösbar durch Neuladen des Moduls

---

## 7. Power Management: 24/7-Serverbetrieb mit geschlossenem Deckel

### Der T2-Chip erzwingt keinen Schlafmodus

Eine verbreitete Befürchtung: Der T2-Chip könnte bei geschlossenem Deckel das System in den Schlafmodus zwingen, unabhängig von den OS-Einstellungen. **Das ist nicht der Fall.** Der Deckelschalter kommuniziert über einen Standard-ACPI-Lid-Switch (`LID0`) mit dem Betriebssystem. Die Entscheidung, was bei geschlossenem Deckel passiert, trifft ausschließlich `systemd-logind` unter Linux. Der T2-Chip hat keine eigene Logik, die den Intel-Prozessor in den Schlafmodus zwingt.

Zusätzlich begünstigt ein Umstand den Serverbetrieb: **S3-Suspend ist auf T2-Macs unter Linux seit dem macOS-Sonoma-Firmware-Update ohnehin defekt.** Der apple-bce-Treiber kann seine USB-Geräte bei Suspend/Resume nicht korrekt ab- und wieder anmelden. Für einen Server, der nie schlafen soll, ist dies sogar vorteilhaft.

### 7.1 systemd-logind konfigurieren

```bash
# Drop-in-Konfigurationsdatei erstellen:
sudo mkdir -p /etc/systemd/logind.conf.d/

cat <<EOF | sudo tee /etc/systemd/logind.conf.d/server.conf
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
HandlePowerKey=ignore
HandlePowerKeyLongPress=poweroff
EOF

sudo systemctl restart systemd-logind
```

**Alle drei `HandleLidSwitch`-Varianten** müssen gesetzt werden — abhängig davon, ob das System Netzteil, Dock oder Batterie erkennt, wird eine andere Variable ausgewertet.

### 7.2 Sleep-Targets vollständig maskieren

```bash
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

# Prüfen:
systemctl status sleep.target suspend.target hibernate.target hybrid-sleep.target
# Alle sollten "masked" anzeigen
```

### 7.3 LID0-Wakeup-Trigger deaktivieren (zusätzliche Absicherung)

```bash
cat <<EOF | sudo tee /etc/systemd/system/disable-lid-wakeup.service
[Unit]
Description=Disable LID wakeup trigger
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'if grep -q "LID0.*enabled" /proc/acpi/wakeup; then echo LID0 > /proc/acpi/wakeup; fi'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable disable-lid-wakeup.service
```

### 7.4 Thermisches Management bei geschlossenem Deckel

Bei geschlossenem Deckel ist die Luftzirkulation eingeschränkt. Der Lüfterauslass beider Modelle sitzt am Scharnier — bei geschlossenem Deckel wird der Luftspalt minimal, aber nicht vollständig blockiert.

**Empfehlungen für den Dauerbetrieb:**

- **Vertikalen Laptop-Ständer verwenden** — exponiert die Unterseite (die bei beiden Modellen als passiver Kühlkörper fungiert) und verbessert die Luftzirkulation erheblich
- **Harte, erhöhte Oberfläche** — niemals auf Stoff oder Teppich stellen
- **Deckel minimal geöffnet lassen** (1–2 cm, z. B. mit einem Binderclip) verbessert den Luftstrom deutlich, insbesondere beim 2020er-Modell
- **Temperaturen überwachen** mit `lm-sensors`:

```bash
sudo apt install lm-sensors
sudo sensors-detect  # Standard-Antworten akzeptieren
watch sensors  # Echtzeit-Temperaturüberwachung
```

Erwartete Temperaturen bei leichter Serverlast: **40–55 °C im Leerlauf**, **50–65 °C bei leichter Last**. Unter Linux laufen T2-Macs typischerweise 5–10 °C heißer als unter macOS aufgrund weniger optimierter Energieverwaltung.

### 7.5 Akkumanagement bei Dauerstrom

Unter Linux existiert **kein „Optimiertes Laden"** wie unter macOS. Der T2-Chip lädt den Akku auf 100 % und hält ihn dort. Dauerhaft bei 100 % gehaltene Lithium-Ionen-Akkus degradieren schneller — realistisch verliert der Akku in 1–2 Jahren etwa 20 % seiner Kapazität.

**Pragmatischer Ansatz:** Den Akku als integrierte USV betrachten. Selbst bei 60–70 % Restkapazität liefert er noch 2–3 Stunden Überbrückungszeit bei Stromausfällen. Ein Akku-Austausch bei Apple kostet ca. 129–159 €. Es gibt aktuell **kein Linux-Tool, das die Ladebegrenzung** auf T2-Macs steuern kann — die SMC-Kontrolle über den Ladezustand ist von Linux aus nicht zugänglich.

---

## 8. Lüftersteuerung mit t2fanrd

Ohne aktive Lüftersteuerung durch einen Userspace-Daemon verlässt man sich auf die Firmware-Level-Steuerung des T2-Chips, die als Sicherheitsnetz funktioniert, aber zu spätes und aggressives Throttling verursachen kann.

```bash
# t2fanrd installieren (aus dem t2linux APT-Repository):
sudo apt install t2fanrd

# Aktivieren und starten:
sudo systemctl enable --now t2fanrd
```

**Konfiguration anpassen:**

```bash
sudo nano /etc/t2fand.conf
```

Konfigurationsoptionen pro Lüfter:

| Schlüssel | Beschreibung | Empfehlung für Server |
|---|---|---|
| `low_temp` | Temperatur (°C), ab der die Lüfterdrehzahl steigt | 45 |
| `high_temp` | Temperatur (°C), ab der die maximale Drehzahl erreicht wird | 75 |
| `speed_curve` | Kurvenform: `linear`, `exponential`, `logarithmic` | `linear` |

Für den Serverbetrieb bei geschlossenem Deckel empfiehlt sich eine **aggressive Lüfterkurve** mit niedrigem `low_temp`-Wert, die den Lüfter frühzeitig aktiviert.

---

## 9. SSD: Besonderheiten der Apple-NVMe-Laufwerke

### Transparente Hardwareverschlüsselung

Der T2-Chip verschlüsselt **alle Daten** auf dem internen SSD permanent mit AES-256, unabhängig von FileVault oder LUKS. Diese Verschlüsselung ist für Linux **vollständig transparent** — das Betriebssystem liest und schreibt Klartext, die Verschlüsselung/Entschlüsselung erfolgt in Echtzeit durch die dedizierte AES-Engine des T2-Chips ohne messbaren Performance-Verlust.

**Konsequenz:** Zusätzliche LUKS-Verschlüsselung ist möglich, aber nicht für den Schutz ruhender Daten nötig. Für einen Server vereinfacht der Verzicht auf LUKS den headless Betrieb (kein Passwort beim Booten erforderlich).

### TRIM aktivieren

```bash
sudo systemctl enable fstrim.timer
```

Dies aktiviert wöchentliches TRIM über den systemd-Timer. Die `discard`-Mount-Option in `/etc/fstab` wird **nicht empfohlen** — periodisches TRIM ist bei NVMe-Laufwerken die bessere Praxis.

### SMART-Daten überwachen

```bash
sudo apt install smartmontools
sudo smartctl -a /dev/nvme0n1
```

---

## 10. Netzwerkkonfiguration für den Serverbetrieb

### Warum USB-Ethernet statt WLAN

**Wi-Fi ist für Kubernetes-Knoten nicht geeignet.** Kubernetes erfordert konstante Inter-Node-Kommunikation (etcd-Konsens, API-Server, Flannel-VXLAN auf UDP 8472), und Wi-Fi bringt variable Latenz und potentiellen Paketverlust mit. Node-Heartbeats können bei WLAN-Unterbrechungen fehlschlagen und Pod-Evictions auslösen.

### 10.1 USB-Ethernet-Adapter: Empfehlungen

| Adapter | Chipsatz | Geschwindigkeit | Linux-Support |
|---|---|---|---|
| **Plugable USBC-TE1000** (~15 €) | RTL8153 | 1 Gbit/s | Plug-and-Play, Treiber im Kernel |
| **UGREEN USB-C Ethernet** (~12 €) | RTL8153 | 1 Gbit/s | Plug-and-Play |
| **Sabrent NT-25GA** (~16 €) | RTL8156 | 2,5 Gbit/s | Kernel 5.x+ |

**Empfehlung:** Jeder Adapter mit **Realtek RTL8153**-Chipsatz funktioniert unter Linux sofort ohne Treiberinstallation. Der RTL8153 ist der am besten unterstützte USB-Ethernet-Chipsatz unter Linux.

### 10.2 Statische IP-Konfiguration mit Netplan

```bash
# Cloud-init Netzwerkkonfiguration deaktivieren:
sudo bash -c 'echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg'

# Netplan-Konfiguration erstellen:
sudo nano /etc/netplan/01-ethernet.yaml
```

```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    # Interface-Name prüfen mit 'ip link show'
    # USB-Ethernet-Adapter bekommen oft Namen wie enx001122334455
    enx001122334455:
      dhcp4: false
      addresses:
        - 192.168.1.100/24
      routes:
        - to: default
          via: 192.168.1.1
      nameservers:
        addresses:
          - 8.8.8.8
          - 1.1.1.1
```

```bash
# Testen (revertiert automatisch nach 120 Sekunden ohne Bestätigung):
sudo netplan try

# Permanent anwenden:
sudo netplan apply
```

**Tipp:** USB-Ethernet-Adapter erhalten oft Interface-Namen basierend auf ihrer MAC-Adresse (z. B. `enx001122334455`). Den korrekten Namen mit `ip link show` ermitteln.

### 10.3 Falls doch WLAN als Backup nötig ist

Falls kein Ethernet-Kabel zum Standort der MacBooks führbar ist, kann das interne WLAN als Notlösung dienen. Alternativ funktionieren USB-Wi-Fi-Adapter mit **MediaTek MT7921AU**-Chipsatz (Treiber `mt7921u` im Kernel seit 5.18) zuverlässiger als die internen Broadcom-Chips.

---

## 11. SSH und Headless-Betrieb einrichten

```bash
# OpenSSH-Server installieren (meist schon bei Ubuntu Server dabei):
sudo apt install openssh-server
sudo systemctl enable ssh

# Konfiguration optimieren:
sudo nano /etc/ssh/sshd_config
```

Empfohlene Einstellungen:

```
PermitRootLogin no
PasswordAuthentication no          # Nur nach SSH-Key-Setup!
PubkeyAuthentication yes
ClientAliveInterval 60
ClientAliveCountMax 3
```

**SSH-Key einrichten (vom lokalen Rechner aus):**

```bash
ssh-copy-id benutzer@192.168.1.100
```

**Fehlerbehebung:**
- *SSH nach Reboot nicht erreichbar:* Netzwerk-Interface prüfen — USB-Ethernet-Adapter könnte einen anderen Namen bekommen haben; Netplan-Konfiguration kontrollieren
- *Serielle Konsole nicht verfügbar:* MacBook Airs bieten **keinen seriellen Konsolenausgang**. Bei Netzwerkproblemen ist physischer Zugang mit externer Tastatur und Monitor (eingebautes Display) erforderlich

---

## 12. k3s-Cluster einrichten

### 12.1 Systemvorbereitung

```bash
# System aktualisieren:
sudo apt update && sudo apt upgrade -y

# Hostname setzen (eindeutig pro Knoten):
sudo hostnamectl set-hostname mba-2020-node  # bzw. mba-2019-node

# Hosts-Datei auf allen Knoten aktualisieren:
echo "192.168.1.100 mba-2020-node" | sudo tee -a /etc/hosts
echo "192.168.1.101 mba-2019-node" | sudo tee -a /etc/hosts

# Firewall deaktivieren (für Homelab einfachste Lösung):
sudo ufw disable

# Alternativ: Benötigte Ports öffnen:
sudo ufw allow 6443/tcp       # K3s API Server
sudo ufw allow 8472/udp       # Flannel VXLAN
sudo ufw allow 10250/tcp      # Kubelet Metrics
sudo ufw allow from 10.42.0.0/16  # Pod-Netzwerk
sudo ufw allow from 10.43.0.0/16  # Service-Netzwerk
```

### 12.2 k3s installieren

Die beiden MacBook Airs mit je **8 GB RAM** und Intel-i5-Prozessoren liegen deutlich über den k3s-Mindestanforderungen (Server: 2 Kerne, 2 GB RAM; Agent: 1 Kern, 512 MB RAM).

**Server-Knoten (Control Plane) installieren:**

```bash
curl -sfL https://get.k3s.io | sh -s - server \
  --write-kubeconfig-mode 644 \
  --node-name mba-2020-node
```

**Node-Token auslesen (benötigt für Agent-Knoten):**

```bash
sudo cat /var/lib/rancher/k3s/server/node-token
```

**Agent-Knoten (Worker) installieren:**

```bash
curl -sfL https://get.k3s.io | K3S_URL=https://192.168.1.100:6443 \
  K3S_TOKEN=<NODE_TOKEN> sh -s - \
  --node-name mba-2019-node
```

### 12.3 Cluster verifizieren

```bash
# Vom Server-Knoten aus:
sudo k3s kubectl get nodes -o wide

# Erwartete Ausgabe:
# NAME            STATUS   ROLES                  AGE   VERSION
# mba-2020-node   Ready    control-plane,master   2m    v1.31.x+k3s1
# mba-2019-node   Ready    <none>                 30s   v1.31.x+k3s1

# Alle System-Pods prüfen:
sudo k3s kubectl get pods -A

# kubectl-Zugang für normalen Benutzer konfigurieren:
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
chmod 600 ~/.kube/config
echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc
source ~/.bashrc
```

**Test-Deployment:**

```bash
kubectl create deployment nginx-test --image=nginx --replicas=2
kubectl expose deployment nginx-test --type=NodePort --port=80
kubectl get svc nginx-test
curl http://localhost:<NodePort>

# Aufräumen:
kubectl delete deployment nginx-test
kubectl delete svc nginx-test
```

---

## 13. Vollständige Checkliste: Vom laufenden macOS zum k3s-Knoten

Diese komprimierte Übersicht fasst alle Schritte zusammen:

1. **Unter macOS:** Wi-Fi-Firmware extrahieren (`firmware.sh`), `pmset -a autorestart 1` setzen, Ubuntu-Server-ISO auf USB-Stick schreiben
2. **Recovery Mode:** Cmd+R → Startup Security Utility → „Ohne Sicherheit" + „Externes Starten erlauben"
3. **USB-Boot:** Option-Taste → EFI Boot → ggf. `efi=noruntime` hinzufügen
4. **Installation:** Manuelle Partitionierung (EFI behalten, macOS-Partitionen löschen), ext4-Root, Swap nach Bedarf
5. **Erster Boot:** Über USB-Ethernet verbinden, t2linux APT-Repository einrichten
6. **T2-Kernel:** `sudo apt install linux-t2-lts apple-t2-audio-config`
7. **Kernel-Parameter:** `intel_iommu=on iommu=pt pcie_ports=compat` in GRUB, `sudo update-grub`
8. **Module:** `echo apple-bce | sudo tee /etc/modules-load.d/t2.conf`
9. **GRUB absichern:** NVRAM schreibgeschützt in `/etc/fstab`, optional rEFInd installieren
10. **Wi-Fi-Firmware:** `sudo get-apple-firmware get_from_online` oder Tarball entpacken
11. **Neustart:** Interne Tastatur, Trackpad und WLAN sollten funktionieren
12. **Power Management:** logind-Konfiguration, Sleep-Targets maskieren, LID0-Wakeup deaktivieren
13. **Lüfter:** `sudo apt install t2fanrd && sudo systemctl enable --now t2fanrd`
14. **TRIM:** `sudo systemctl enable fstrim.timer`
15. **Statische IP:** Netplan-Konfiguration für USB-Ethernet
16. **SSH:** Key-basierte Authentifizierung einrichten
17. **k3s:** Server- oder Agent-Installation, Cluster-Verifizierung

---

## Was aktuell nicht funktioniert und offene Probleme

**Touch ID** ist unter Linux nicht nutzbar — der Secure-Enclave-Chip des T2 hat keinen Linux-Treiber und wird ihn voraussichtlich nie bekommen. **Suspend/Resume** ist seit dem macOS-Sonoma-Firmware-Update defekt und für den Serverbetrieb irrelevant. **Akkuladebegrenzung** ist von Linux aus nicht steuerbar — der Akku wird dauerhaft auf 100 % gehalten. **Audio-Qualität** der eingebauten Lautsprecher ist deutlich schlechter als unter macOS (fehlendes DSP-Processing) — für einen Server ohne Bedeutung.

Das t2linux-Projekt wird aktiv weiterentwickelt. Touch-Bar-Treiber und Apple-T2-Device-Trees wurden bereits in den Mainline-Linux-Kernel 6.15 aufgenommen, der apple-bce-Treiber für Tastatur und Trackpad ist jedoch weiterhin Out-of-Tree und wird über den gepatchten t2linux-Kernel bereitgestellt. Für die absehbare Zukunft bleibt der t2linux-Kernel eine Notwendigkeit für den vollen Hardwaresupport.