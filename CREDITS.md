# Credits

Transmission Remote Mac is an independent native macOS client for the Transmission RPC interface. It is built with Swift and SwiftUI.

Transmission is a separate open-source project. This application does not bundle the Transmission daemon and is not affiliated with the Transmission project or legacy Transmission Remote GUI applications.

## Behaviour reference

Transmission Remote GUI is the behaviour and RPC compatibility reference for this native implementation:

- Repository: `https://github.com/lighterowl/transgui`
- Pinned revision: `6b8a09eed8f5705c71dc39dd913c65a359dcfb1b`
- Copyright (c) 2008-2019 by Yury Sidorov and Transmission Remote GUI working group
- Copyright (c) 2023-2024 by Daniel Kamil Kozar

The reference project is distributed under the GNU General Public License version 2 or later, with the additional exception stated in its source notices. Transmission Remote Mac preserves the upstream attribution while implementing the macOS interface natively in Swift.

Transmission Remote Mac is distributed under the GNU General Public License version 2. See `LICENSE` for the complete terms.

## Application icon

The application icon is project-specific artwork created for Transmission Remote Mac using Gemini image-generation tooling under contributor direction. Its red gearstick and up/down arrows reference the legacy Transmission Remote GUI Mac icon, using a new rendering rather than its original image asset. It is distributed with the application under the same GPLv2 terms.

`Resources/AppIcon.png` is the canonical transparent 1024 by 1024 source. `Resources/AppIcon.icns` contains the standard and Retina representations generated from that source with macOS `sips` and `iconutil`. The highest-resolution representation preserves the canonical pixel data and transparency.

## Optional country database

Transmission Remote Mac can download and manually update the latest DB-IP Country Lite CSV from Application Settings. An empty custom source URL uses DB-IP's published download; users can instead supply an HTTPS URL for a compatible CSV or gzip-compressed CSV, or import a local CSV. Downloads occur only when requested, and the database is not bundled with the application. Peer country lookups run locally; peer IP addresses are never sent to the database provider.

Custom database URLs are saved locally but omitted from exported settings because they may contain private access tokens. Re-enter a custom source after importing settings on another installation.

- Source: [DB-IP Country Lite](https://db-ip.com/db/download/ip-to-country-lite)
- Provider: DB-IP.com
- License: [Creative Commons Attribution 4.0 International](https://creativecommons.org/licenses/by/4.0/)
