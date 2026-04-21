# CodeMySpec

AI-powered specification-driven development for Phoenix applications.

## Installation (Claude Code Plugin)

Inside Claude Code:

```
/plugin marketplace add Code-My-Spec/plugins
/plugin install codemyspec@codemyspec
```

The CLI binary auto-installs on first SessionStart.

### Troubleshooting

**macOS security warning:** If macOS blocks the binary, allow it in System Preferences > Security & Privacy.

**Permission denied:** Run `chmod +x bin/cms`

---

## Development Setup

To start your Phoenix server:

  * Run `mix setup` to install and setup dependencies
  * Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

## CLI Development

Run the CLI in development mode:

```bash
MIX_ENV=cli mix cli
```

## Releasing the Claude Code Extension

The project includes a Burrito-based release system that packages the CLI as a standalone binary and generates a Claude Code plugin.

### Build Only (no publish)

```bash
MIX_ENV=cli mix release --overwrite
```

This generates:
- `release/codemyspec-extension/` - Claude Code plugin files
- `release/binaries/cms-darwin-arm64` - Standalone CLI binary

### Build and Publish to GitHub

```bash
PUBLISH_RELEASE=true MIX_ENV=prod mix release --overwrite
```

This will:
1. Build the Burrito binary
2. Package the Claude Code plugin marketplace artifact
3. Push marketplace files (incl. `.claude-plugin/marketplace.json` and `plugins/codemyspec/`) to [Code-My-Spec/plugins](https://github.com/Code-My-Spec/plugins)
4. Create a GitHub Release and upload the binary

**Requirements:**
- `gh` CLI installed and authenticated (`gh auth login`)
- Write access to the extension repository

### Versioning

Update the version in `CodeMySpec/.claude-plugin/plugin.json` before releasing:

```json
{
  "name": "codemyspec",
  "version": "1.0.0",
  ...
}
```

### Release Output Structure

```
release/
├── codemyspec-extension/                    # Push to Code-My-Spec/plugins
│   ├── .claude-plugin/
│   │   └── marketplace.json                 # Marketplace manifest
│   ├── plugins/
│   │   └── codemyspec/                      # The plugin itself
│   │       ├── .claude-plugin/plugin.json
│   │       ├── hooks/
│   │       ├── agents/
│   │       ├── skills/
│   │       └── bin/cms                      # populated by auto-update
│   ├── install.sh                           # Manual-install fallback
│   └── README.md
└── binaries/
    └── cms-darwin-arm64                     # Upload to GitHub Release
```

## Learn more

  * Official website: https://www.phoenixframework.org/
  * Guides: https://hexdocs.pm/phoenix/overview.html
  * Docs: https://hexdocs.pm/phoenix
  * Forum: https://elixirforum.com/c/phoenix-forum
  * Source: https://github.com/phoenixframework/phoenix

## Known Issues

### Rambo gets fucked

Whenever you pull the project from scratch, rambo gets fucked and ngrok won't work.
You have to go to `deps/rambo/priv` and rename rambo-mac to rambo.