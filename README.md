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

Update the version in `plugins/claude/.claude-plugin/plugin.json` before releasing:

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

## Building on Windows

This project has C and Rust NIF dependencies (`bcrypt_elixir`, `lumis`) that must
be compiled with Microsoft's MSVC toolchain. On a fresh Windows checkout `mix compile`
fails with errors like:

```
** (Mix) "nmake" not found in the path.
```

This is **not** a missing C++ *Redistributable* (that's only the runtime DLLs). You
need the MSVC *build tools* (`nmake.exe`, `cl.exe`), and they only exist inside a
"Developer" environment — they are never added to your global `PATH`.

### Prerequisites

1. **Visual Studio Build Tools 2022** with the **"Desktop development with C++"**
   workload (provides `nmake`, `cl`, and `vcvars64.bat`).
   - Install via winget: `winget install Microsoft.VisualStudio.2022.BuildTools`
   - Then in the Visual Studio Installer, add the **Desktop development with C++**
     workload.
   - Verify it's present:
     ```powershell
     & "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe" `
       -products * -property installationPath
     # then confirm this file exists:
     # <installPath>\VC\Auxiliary\Build\vcvars64.bat
     ```
2. **Erlang/OTP** and **Elixir** matching the project (this project builds on
   Elixir 1.20 / OTP 29). Make sure your Erlang architecture is **x64** so the
   x64-targeting `vcvars64.bat` matches.

> Already have it? You probably do not need to install anything — the toolchain is
> usually present, just not on `PATH`. Skip to **Compiling** below.

### Compiling

The MSVC environment must be loaded *before* `mix`. Pick one:

#### Option 1 — One-shot wrapper

```powershell
cmd /c '"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul && mix compile'
```

#### Option 2 — Load the env into your current PowerShell session, then use `mix` normally

```powershell
$vcvars = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
cmd /c "`"$vcvars`" >nul && set" | ForEach-Object {
  if ($_ -match '^([^=]+)=(.*)$') { Set-Item -Path "Env:\$($matches[1])" -Value $matches[2] }
}

# now everything just works for the rest of the session:
mix deps.get
mix compile
mix test
iex -S mix
```

#### Option 3 — Developer shell (zero setup)

Start menu → **"Developer PowerShell for VS 2022"** (or "Developer Command Prompt").
It boots with the MSVC env already applied. `cd` to the repo and run `mix compile`.

> Only the NIF deps need the MSVC env. Once they're built into `_build`, plain
> `mix compile` works again until a NIF is forced to rebuild (`mix deps.clean`,
> a fresh checkout, etc.).

### Known dependency issues on Elixir 1.20 / OTP 29

This project tracks a bleeding-edge toolchain; a few deps need help.

#### `faker` — `invalid line break character in string: `

```
== Compilation error in file lib/faker/string.ex ==
** (SyntaxError) invalid syntax found on lib/faker/string.ex:143:16:
     error: invalid line break character in string:  ...
```

`faker` (a non-optional transitive dep of `oapi_github`) has a raw U+0085 (NEL)
character in `lib/faker/string.ex` line 143 that the Elixir 1.20 lexer rejects.
**No released faker version fixes this** (master, 0.18.0, and 0.19.0-alpha.1 all
ship the same broken file).

**Local unblock** — patch the vendored copy in place (escapes the offending
line-break code points; safe because we don't use `Faker.String`):

```powershell
$path = "deps\faker\lib\faker\string.ex"
$in = [System.IO.File]::ReadAllBytes($path)
$seqs = @(
  @{ bytes=@(0xC2,0x85);      repl='' },   # U+0085 NEL -> removed
  @{ bytes=@(0xE2,0x80,0xA8); repl=' ' },  # U+2028 line sep -> space
  @{ bytes=@(0xE2,0x80,0xA9); repl=' ' }   # U+2029 para sep -> space
)
$out = New-Object System.Collections.Generic.List[byte]
$i = 0
while ($i -lt $in.Length) {
  $matched = $false
  foreach ($s in $seqs) {
    $n = $s.bytes.Length
    if ($i + $n -le $in.Length) {
      $eq = $true
      for ($k=0; $k -lt $n; $k++){ if ($in[$i+$k] -ne $s.bytes[$k]){ $eq=$false; break } }
      if ($eq) {
        foreach ($c in [System.Text.Encoding]::ASCII.GetBytes($s.repl)) { $out.Add($c) }
        $i += $n; $matched = $true; break
      }
    }
  }
  if (-not $matched) { $out.Add($in[$i]); $i++ }
}
[System.IO.File]::WriteAllBytes($path, $out.ToArray())
```

> ⚠️ This edits `deps/faker/`, which is **not durable** — `mix deps.clean faker`,
> a fresh clone, or CI will wipe it and the error returns. For a permanent fix,
> point at a patched fork: `{:faker, git: "https://github.com/<you>/faker", branch: "...", override: true}`.

#### `meck` — `'catch ...' is deprecated`

`meck` ≤ 0.9.x fails to compile on OTP 29 (deprecated `catch` syntax, treated as
an error). Already resolved in this project: `meck` is pinned to `~> 1.2` via the
`ex_cli_vcr` dependency. If you see this error, run `mix deps.update meck` and make
sure nothing pins `meck ~> 0.9`.

### Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `"nmake" not found in the path` | MSVC env not loaded | Load `vcvars64.bat` (see **Compiling**) |
| `nmake`/`cl` missing even after vcvars | C++ workload not installed | Add **Desktop development with C++** in the VS Installer |
| `vcvars64.bat` not found | Build Tools not installed | `winget install Microsoft.VisualStudio.2022.BuildTools` + C++ workload |
| `faker` U+0085 syntax error | broken faker on Elixir 1.20 | Apply the local patch above |
| `meck` deprecated `catch` | old meck on OTP 29 | `mix deps.update meck` (needs `~> 1.2`) |
| Makefile "path contains spaces" warning | repo path has a space | Harmless for these deps; ignore |

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
