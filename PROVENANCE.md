# Provenance, Naming Notes & Licensing

## 1. Snapshot Origin

- **Display Name / Repository Slug:** `Veypane` / `veypane`
- **Anchored Local Branch & Revision:** `fix/veypane-narrow-sidebar` @ `5c1a98b8f442eeb05eff5b80b6d05fe25d82b599` (`1.2.10` build `13`, `32` sequential local commits)
- **Export Method:** Clean allowlist export excluding internal development specifications (`SPEC.md`), UX comparison notes (`COMPARE-UX.md`), agent rule files (`AGENTS.md`, `ROUND5-ICON.md`), build caches, local logs, compiled bundles, and local git commit history.

## 2. License

- **Active License:** MIT License (`LICENSE`, `Copyright (c) 2026 Lorin Lee`).
- **Scope Note:** Apple macOS system frameworks, WebKit, macOS system fonts, and Apple SF Symbols are linked/invoked only at runtime and are **not** redistributed or relicensed under MIT (see `NOTICE.md` and `THIRD_PARTY_NOTICES.md`).
- **Repository:** Open-source release snapshot (`https://github.com/lorinlee/veypane`).

## 3. Name Screening Notes (`Veypane`)

- Preliminary software-name checks performed on `2026-11-21` found zero exact-name matches across general web search, GitHub repository search (`Veypane in:name,description,readme`, `total_count: 0`), Apple iTunes Mac software search (`entity=macSoftware`, US and CN, `resultCount: 0`), and Chrome Web Store search (`No search results`).
- **Limitations:** A differently spelled App Store app named `ViewPane` (a Frigate NVR camera companion app) exists. Preliminary checks are not a global trademark registry clearance.

## 4. Assets

- The three icon binary files (`Assets/AppIcon/Veypane-1024.png`, `Assets/AppIcon/Veypane.icns`, and `Sources/VeypaneCore/Resources/Veypane.icns`) can be regenerated directly from source using:

```bash
swift scripts/generate-icon.swift
```

- The README hero illustration (`Assets/README/veypane-hero.webp`, `1280×720` WebP) is an AI-generated decorative brand illustration (not a product UI screenshot) created specifically for this project (see `Assets/README.md`).
