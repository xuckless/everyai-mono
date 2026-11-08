# get.everyai.dev: the install scripts

- `public/install.sh`: macOS and Linux (`curl -fsSL https://get.everyai.dev/install.sh | sh`, `--uninstall`).
- `public/install.ps1`: Windows, the Microsoft Store app through winget (`irm https://get.everyai.dev/install.ps1 | iex`).
- `worker.js`: the Cloudflare worker `everyai-get` on `get.everyai.dev`. It serves the scripts, the Linux release key,
  the app icon and `/latest/version` (GitHub's latest release, cached 5 minutes). `/` gives curl/wget the shell
  script, PowerShell the .ps1, and sends browsers to the README. The packages download from GitHub Releases.
- `deploy.sh`: copies the key and icons into `public/` and runs `wrangler deploy`. Run it after changing a script.
  Releases need nothing here: the scripts look up the version each time.

Tested (2026-11-07): macOS into a scratch folder (checksum, team 2MGLZ5685D signature, Gatekeeper); Ubuntu 24.04
(.deb through apt, GPG check, uninstall); Fedora 41 as a normal user (AppImage, menu entry, icons, `everyai://` handler,
no-FUSE fallback, uninstall). Docker on Apple Silicon can't run the AppImage runtime, so there the icons come from
`get.everyai.dev`. The .ps1 hasn't run on Windows yet.
