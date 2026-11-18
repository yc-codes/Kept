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

## Share to Kept

Open the built app once, then choose **Share → Kept** in a Mac app to save a link, selected text, or an image. Share one item at a time. If Kept is hidden, enable it in the Share menu’s extension settings. Sharing works even when clipboard capture is paused.

## Layout

| Path | What |
|---|---|
| `Sources/KeptCore` | Item model, SQLite + FTS5 store, image helpers. Shared by app and MCP server. |
| `Sources/Kept/Services` | Capture settings, clipboard monitor, snip, global shortcuts, library store. |
| `Sources/Kept/Connectors` | Connectors: sign in to a service and keep saving what you save there. |
| `Sources/Kept/Views` | Library window, inspector, welcome flow, quick search panel, settings. |
| `Sources/KeptMCP` | `kept-mcp`, a stdio MCP server (`search_library`, `get_item`, `list_recent`). |
| `scripts/` | App bundle and icon build. |

The library lives in `~/Library/Application Support/Kept` (`kept.sqlite`, `assets/`, `thumbs/`).

## Connectors

Settings › Connectors pulls in what you save elsewhere. Each connection has its own sign-in, so the same
service can be added more than once (two GitHub accounts, several feeds). Kept syncs at launch and about
every half hour, and only ever reads from the service.

| Connector | Sign-in | Saves |
|---|---|---|
| GitHub Stars | Personal access token (read-only Starring) | Starred repositories, as links |
| Raindrop.io | Test token from your Raindrop app settings | Bookmarks, as links |
| RSS or Atom Feed | None | Feed entries, as links |

Tokens live in the Keychain, never in the library. A connection remembers what it has delivered, so an
item you delete does not come back, and a link already in the library is not saved twice.

To add a connector, write one type conforming to `Connector` (`Connectors/Connector.swift`; copy one from
`Connectors/BuiltIn`) and list it in `ConnectorRegistry.all`. It declares its sign-in fields and implements
`verify` and `fetch`; the settings row, sign-in sheet, Keychain storage, scheduling and de-duplication come
from the framework. Sign-in is by token or key for now; there is no browser (OAuth) sign-in yet.

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
- With either of those set, connector sign-ins go to a separate Keychain service. `KEPT_GITHUB_API` and
  `KEPT_RAINDROP_API` point those connectors at another server, such as a local test double.
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

## Website

The product website lives in `website/`. To preview it locally with Python 3:

```sh
python3 -m http.server 4173 --directory website
```

Open http://localhost:4173. The site is static and can be served directly from
`website/`. The interactive demo uses sample data, and the library previews
are screenshots from the native app with a separate sample library.
