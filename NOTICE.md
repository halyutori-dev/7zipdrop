# Third-party components

## 7-Zip (bundled)

This application bundles the official 7-Zip console executable (`7zz`) and invokes it as
a separate process to create archives.

- Component: 7-Zip for macOS, console version — `7zz`
- Version: **26.02** (released 2026-06-25)
- Copyright: (C) 1999-2026 Igor Pavlov
- License: **GNU LGPL** (full text in `Contents/Resources/ThirdParty/7-Zip/License.txt`)
- Home page and source code: <https://www.7-zip.org/>
- Bundled from: <https://github.com/ip7z/7zip/releases/download/26.02/7z2602-mac.tar.xz>
- Verified SHA-256 of that archive: `1cf6760579502f87e591ff5c73a005ec50b3e4d6f507e8b038382d563c3175b9`

7-Zip is used **unmodified** and is executed as a separate program (`exec`), not linked
into this application. The 7-Zip source code corresponding to the bundled binary is
published by its author at <https://www.7-zip.org/> and mirrored at
<https://github.com/ip7z/7zip>.

Per the 7-Zip FAQ's terms for redistributing compiled binaries, this notice records that
7-Zip components are used, states the GNU LGPL license, and links to www.7-zip.org.

`scripts/fetch-7zz.sh` re-downloads the same release and **refuses to install it unless
the SHA-256 and byte size match** the values above, so the provenance of the bundled
binary is reproducible rather than trusted by assumption.
