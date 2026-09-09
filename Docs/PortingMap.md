# Porting Map

Source behaviour reference: [`lighterowl/transgui`](https://github.com/lighterowl/transgui) at revision `6b8a09eed8f5705c71dc39dd913c65a359dcfb1b`. A sibling `transgui` checkout is convenient for development but is not required by this repository.

## Direct behaviour targets

- `rpc.pas`: Transmission RPC session handling, session-id retry, request fields, and RPC version gates.
- `torrentcolumns.pas`: main torrent list data model.
- `filtering.pas`: status/path/tracker/label filters.
- `addtorrent.pas`: add torrent flow, file tree, wanted flags, and priorities.
- `daemonoptions.pas`: session-get/session-set preferences.
- `localfilemanager.pas`, `urllistenerosx.pas`: macOS Finder reveal and URL event behaviour.

## Swift split

- `Services`: RPC, decoding, bencode parsing, URL ingestion, filtering, path mapping, and local file actions.
- `Models`: torrent/session/connection data.
- `Stores`: main-window state and polling.
- `Views`: SwiftUI app shell and feature surfaces.
- `Support`: formatting, small extensions, AppKit bridges when needed.

## AppKit boundaries

- Dense torrent table if SwiftUI `Table` cannot keep parity with column setup, selection stability, and context-menu behaviour.
- Finder reveal/open actions, native prompts, URL/file open events, and notification authorization use platform APIs where SwiftUI does not own the workflow.
- The current SwiftUI file outline supports wanted and priority mutation; move to AppKit only if deeper tree interaction requires it.
