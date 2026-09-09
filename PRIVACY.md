# Privacy

Transmission Remote Mac connects directly from your Mac to Transmission RPC servers that you configure. It does not route RPC traffic through an application-operated service.

Connection profiles and preferences are stored locally. RPC and proxy passwords, plus imported TLS client private keys, are stored in macOS Keychain rather than profile files. Security-scoped watch-folder bookmarks stay on the Mac and are excluded from redacted settings exports. Torrent names, paths, magnet links, server addresses and RPC responses may be visible to the configured Transmission server and its network operator.

Clipboard intake, watch-folder automation, source `.torrent` deletion and automatic update checks are opt-in. Source cleanup is attempted only after Transmission confirms a non-duplicate add, and watch-folder failures remain visible for review.

The application does not include advertising or remote analytics. Local diagnostics may be written to the macOS unified log to measure RPC timing and failures, without intentionally logging credentials, session identifiers, request bodies or torrent content.

Connections using plain HTTP are not encrypted. Use HTTPS, a trusted private network or a VPN when credentials or torrent activity require protection. macOS may request Local Network access so the application can reach servers on your local network.

Removing a saved server removes its stored profile. Keychain data can also be inspected or removed using macOS Keychain Access.
