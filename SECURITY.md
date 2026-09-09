# Security Policy

## Supported versions

Until the first public release, security fixes target `main`. After release, fixes target the latest published version and `main`. An older release is supported only when its own maintenance branch is announced.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use [GitHub private vulnerability reporting](https://github.com/transmission-remote-mac/transmission-remote-mac/security/advisories/new) so the report and any response remain private while the problem is assessed.

Include:

- the affected app and Transmission daemon versions
- the security impact
- the smallest reproducible sequence
- any relevant RPC method or local macOS behavior
- a suggested fix, when you have one

Remove passwords, tokens, private host names, torrent metadata and other personal information. A test case should use the deterministic mock RPC server whenever the behavior can be reproduced there.
