# Contributing

Bug reports, focused fixes and pull requests are welcome. For larger features or architectural changes, open an issue first so we can agree on the scope.

Report suspected vulnerabilities through the private route in [SECURITY.md](SECURITY.md), not through a public issue.

## Pull requests

- Fork the repository, create a topic branch and open your pull request against `main`.
- Explain the user-visible problem, the change and how you verified it. Include a regression test for a bug fix where practical.
- Keep unrelated changes and whole-file formatting out of functional patches.
- Do not include credentials, private server addresses, user preferences, signing identities or screenshots containing private torrent or tracker information.
- Use the deterministic mock for mutations. Never run destructive tests against a real Transmission server.

`main` is the integration branch. Releases are immutable version tags, not a separate copy of the source on a permanent release branch. A maintenance branch is only needed if an older release must receive fixes independently.

## Source style and ownership

Follow the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/) and the surrounding code. Types use UpperCamelCase; methods and properties use lowerCamelCase with meaningful argument labels.

- Use four spaces, LF line endings, a final newline and no trailing whitespace. `.editorconfig` records the editor defaults.
- Prefer a 120-character margin for new expressions. Keep existing declaration layout and readable literals rather than mechanically wrapping method signatures or URLs.
- `.swift-format` supplies matching indentation and collection defaults for Xcode's `swift-format`. Its layout suggestions are advisory, not a claim that the existing tree is formatter-clean. Review formatting on the code you edit; do not run an automatic whole-tree rewrite. CI enforces source hygiene rather than grandfathering a large warning baseline.
- Models own typed values, RPC DTOs and domain state. Services own reusable validation, mapping, persistence, transport and platform behavior. Stores own application orchestration, user intents and connection generations. Views render values and dispatch intents.
- Reuse an existing abstraction before introducing another type. Keep AppKit bridges narrow and publish back to the store or SwiftUI source of truth.
- Preserve cancellation, stale-response rejection, connection ownership and frozen torrent identity. Cached display data must never authorize a mutation. Keep RPC field and version gates exact.
- Keep work bounded for large torrent lists and file trees. Avoid repeated RPC fields, unchanged publications and render-time filesystem work. Do not remove functionality to make a benchmark pass.

## Verification

Use Xcode on macOS 14 or later. From the checkout:

```sh
python3 script/check_source_hygiene.py
python3 -m unittest discover -s script -p 'test_*.py'
for script in script/*.sh script/lib/*.sh; do bash -n "$script" || exit; done
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -Xswiftc -warnings-as-errors
git diff --check
```

The GitHub Actions checks run these noninteractive checks without signing credentials. They compile and test the package; they do not sign or publish a release. Changes to native UI also need a short real-workflow check using the signed development app:

```sh
./script/build_and_run.sh --verify
```

See [README.md](README.md) for local signing configuration and mock server setup. The script installs and opens `/Applications/TransmissionRemoteMac.app`; save your work before running it. Do not change another user's settings or Keychain items for a test. Long performance acceptance is opt-in release work, not the routine feature-development loop.

Planned GitHub binaries will be packaged with `script/release_unnotarized.sh`, signed with the maintainer's fixed `Transmission Remote Mac Release` self-signed identity, and labelled as non-notarized. `Resources/ReleaseSigningCertificate.cer` is public identity-pin material only; contributors and users must not install or trust it, and its matching private key must never enter the repository or a release. Developer ID signing and notarization remain an optional future maintainer path through `script/release.sh`; they are not required for ordinary contributions.

## Copyright and license

The project is distributed under GPL-2.0-only, as declared in [LICENSE](LICENSE) and [CREDITS.md](CREDITS.md). Contributions are submitted under the same license; contributors retain their copyright. No copyright assignment is required.

Keep existing notices and upstream attribution. New source files should begin with a short project/SPDX notice, using the actual copyright holder and year, not automatically attributing outside contributions to the maintainer:

```swift
// Transmission Remote Mac
// SPDX-FileCopyrightText: YEAR Copyright holder
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.
```

For scripts, use `#` comments after the shebang. `Package.swift` must keep its `swift-tools-version` directive first. Add applicable third-party notices when adapting code; a project header does not replace its original attribution or grant permission to relicense it.
