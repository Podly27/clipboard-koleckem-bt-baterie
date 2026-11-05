# Clipboard kolečkem a stav baterie BT

*Middle-click Clipboard & Bluetooth Battery*

[Česky](#česky) · [English](#english)

## Česky

Malá aplikace pro macOS, která v horní liště ukazuje baterii Bluetooth myši a klávesnice. Vznikla pro Eternico MV400 a ET-K200FBT1; u jiných zařízení záleží na tom, jak hlásí stav baterie.

**[Stáhnout českou verzi](https://github.com/Podly27/clipboard-koleckem-bt-baterie/releases/latest/download/BT-Battery-CZ.zip)** · [Vydání](https://github.com/Podly27/clipboard-koleckem-bt-baterie/releases)

1. Rozbal ZIP, přesuň **Baterie BT.app** do Aplikací a spusť ji. Balíček je podepsaný lokálně a není notarizovaný společností Apple.
2. Povol Bluetooth pro čtení baterií. Pro kolečko a klávesovou zkratku povol aplikaci v **Nastavení systému → Soukromí a zabezpečení → Zpřístupnění**.
3. Pokud chceš automatické spouštění, přidej aplikaci mezi přihlašovací položky.

- Baterie: zelená nad 30 %, oranžová 21–30 %, červená 0–20 %. Otazník znamená nedostupný údaj. Hodnoty se mohou lišit od Nastavení Bluetooth.
- Krátký stisk kolečka v rozpoznaném textovém poli vloží text ze systémové schránky. Označení textu myší jej v podporovaných aplikacích zkopíruje do stejné schránky. Podržením kolečka zobrazíš až 10 posledních různých textů; historie zůstává jen v paměti do ukončení aplikace.
- **Option nebo Win (Command) + levý Shift** přepíná mezi **Czech** a **US International PC**, pokud jsou oba vstupní zdroje přidané v macOS.

## English

A small macOS menu bar app for Bluetooth mouse and keyboard battery levels. Built for the Eternico MV400 and ET-K200FBT1; other devices depend on whether they report battery levels.

**[Download the English version](https://github.com/Podly27/clipboard-koleckem-bt-baterie/releases/latest/download/BT-Battery-EN.zip)** · [Releases](https://github.com/Podly27/clipboard-koleckem-bt-baterie/releases)

1. Unzip, move **BT Battery.app** to Applications, and launch it. The build is ad-hoc signed and not notarized by Apple.
2. Allow Bluetooth access to read battery levels. For middle-click paste and the keyboard shortcut, grant Accessibility access in **System Settings → Privacy & Security → Accessibility**.
3. Optionally add the app to Login Items.

- Battery colors: green above 30%, orange 21–30%, red 0–20%. A question mark means no reading is available. Readings may differ from Bluetooth Settings.
- A short middle click in a recognized text field pastes text from the system clipboard. Selecting text with the mouse copies it to the same clipboard in supported apps. Hold the middle button to pick from up to 10 recent distinct texts. History is held in memory and cleared when the app quits.
- **Option or Win (Command) + Left Shift** toggles **Czech** and **US International PC** when both input sources are configured.

### Build / Sestavení

macOS 13+ target; universal binaries for Apple Silicon and Intel. Build with Xcode Command Line Tools:

```sh
./build.sh
```

Both ZIP files are written to `dist/`. Install only one language edition at a time; both use the same bundle identifier.
