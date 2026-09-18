# Privacy Policy

**Glassmark does not collect any data.**

Glassmark is a local macOS Markdown editor. It has no accounts, no analytics, 
and no telemetry. Your documents and folders stay on your Mac — the only
exception is the text you explicitly submit when you use the optional AI
editing feature described below.

* **No data collected.** Glassmark does not gather, store, or transmit any
  personal information or usage data on its own. The only outbound request the
  app can make is the AI editing request you trigger yourself.
* **No tracking.** There are no analytics or advertising frameworks.
* **Local only.** Files you open and edit are read from and written to the
  locations you choose on your own device, using macOS security-scoped access.
* **Offline rendering.** Code highlighting, math, and diagrams in the preview
  are rendered entirely on-device from assets bundled in the app — nothing is
  fetched from the internet.
* **No update checks.** Glassmark does not check for updates and never downloads
  new versions on its own.
* **Optional AI editing (off by default).** When you enable it and run an edit, 
  the text you selected and the instruction you typed are sent to Google's
  Gemini API ( `generativelanguage.googleapis.com` ) using your own API key, with
`store: false` so the API does not keep the interaction for state or
  observability. The key is stored in the macOS Keychain and is never written to
  preferences, logs, or the repository. Note that Google's terms differ between
  free and paid API tiers (for example, free-tier content may be used to improve
  models); review the [Gemini API terms](https://ai.google.dev/gemini-api/terms)
  before use.

Because no data is collected, there is nothing to share, sell, or delete on a
server.

If you have any questions about privacy, please open an issue at
<https://github.com/nerkza/GlassMark/issues>.

_Last updated: 18 September 2026._
