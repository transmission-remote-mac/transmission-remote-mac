## What changed

Describe the user-visible or technical change.

## Why

Explain the problem this solves. Link the relevant issue when one exists.

## Verification

List the checks you ran and their results. Delete checks that do not apply.

- [ ] Source hygiene
- [ ] Mock RPC and tooling tests
- [ ] Shell syntax
- [ ] Swift tests with warnings as errors
- [ ] Signed native app workflow check

## Safety and scope

- [ ] Mutating RPC behavior was tested against the deterministic mock, not a live Transmission server.
- [ ] The change contains no credentials, private server details or screenshots showing private torrent data.
- [ ] The patch contains no unrelated formatting or generated build output.
- [ ] New RPC fields and methods use the correct Transmission RPC version gates.

## Screenshots

Include before and after screenshots for visible changes. Use the mock RPC server and remove private information.
