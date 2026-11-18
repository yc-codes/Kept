# Kept

A local-first capture library for Mac. Snip part of the screen and keep working: the snip is on your
clipboard and saved once in your library. Optionally keep copied images, links and text. Add your own
note to anything, search it all (including text inside images), and let Claude Code or Codex look
things up through a read-only MCP server.

Product background: `../mac-capture-library-brief.md`.

## Build and run

Needs only the Xcode Command Line Tools (Swift 6, macOS 14+ SDK).

```sh
scripts/build-app.sh        # builds build/Kept.app
open build/Kept.app
```

The build is ad-hoc signed. macOS ties Screen Recording permission to the signature, so it asks again
after every rebuild. To keep the permission, sign with a stable identity:
`KEPT_SIGN_IDENTITY="Apple Development: …" scripts/build-app.sh`.

## Layout

| Path | What |
|---|---|
| `Sources/KeptCore` | Item model, SQLite + FTS5 store, image helpers. Shared by app and MCP server. |
| `Sources/Kept/Services` | Capture settings, clipboard monitor, snip, global shortcuts, library store. |
| `Sources/Kept/Views` | Library window, inspector, welcome flow, quick search panel, settings. |
| `Sources/KeptMCP` | `kept-mcp`, a stdio MCP server (`search_library`, `get_item`, `list_recent`). |
| `scripts/` | App bundle and icon build. |

The library lives in `~/Library/Application Support/Kept` (`kept.sqlite`, `assets/`, `thumbs/`).

## Connect an agent

Settings › Agents shows these with the right path filled in:

```sh
claude mcp add --scope user kept -- "/path/to/Kept.app/Contents/MacOS/kept-mcp"
codex mcp add kept -- "/path/to/Kept.app/Contents/MacOS/kept-mcp"
```

Items are cited as `kept://item/<id>`, which opens the exact item in the library.

## Development notes

- `@State` is a macro in the current SDK and its compiler plugin ships only with Xcode. Views use
  `@Local` (`Sources/Kept/Views/Local.swift`) instead so the package builds without Xcode.
- `KEPT_HOME=<dir>` points the app and `kept-mcp` at a different library, and
  `KEPT_DEFAULTS_SUITE=<name>` isolates preferences. Use both for test runs.
- `KEPT_SNAPSHOT_DIR=<dir>` makes the app render its windows to PNG and quit
  (see `Services/DebugSnapshot.swift`).

## Not built yet

Generated descriptions (local model / own API key), readable-page capture for links, multi-select,
export, launch at login.

## Adding things

Snip (`⌃⌥S`), copy with a clipboard source switched on, drop images, GIFs, links or text onto the
library window, File › Import Images… (`⌘O`), or open an image with Kept. GIFs are stored unchanged
and animate in the inspector.

The in-app illustrations (`Views/Illustrations.swift`) are drawn in SwiftUI rather than shipped as
image files, so they follow light and dark mode and stop when Reduce Motion is on.
