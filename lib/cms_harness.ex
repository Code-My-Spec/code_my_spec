defmodule CmsHarness do
  @moduledoc """
  The light harness: the half of CodeMySpec that owns a disk.

  It watches a working copy, classifies what it finds, runs analyzers against
  it, and reports the conclusions up a channel to the server. It holds no
  database — no Repo, no schemas, no migrations — and that absence is the
  design rather than an unfinished piece of it. The server owns the model; this
  owns the bytes. Wanting a Repo in here is the signal that something belongs
  on the server instead.

  The one exception is `CmsHarness.Migrate` — `cms migrate`, a separate
  one-shot boot of the same release that imports a local CLI database to the
  cloud and halts. It never runs inside the harness.

  Kept as its own top-level namespace rather than folded into `CodeMySpec`, and
  the collisions are the reason it reads like duplication when it is not:

    * `CmsHarness.Projects` is a *process registry* — which working copies this
      harness currently serves. `CodeMySpec.Projects` is a context over rows.
    * `CmsHarness.Analysis` runs an analyzer and hands back what it printed.
      `CodeMySpec.Analysis` turns that into Problems and records the run.

  Merging either pair produces one module that branches on whether it has a
  database, which is the shape `CodeMySpec.Issues` already took and the reason
  this stayed separate.

  What is genuinely shared is shared: the scanner, the document parsers, the
  analyzer executors and `Environments` all come from `CodeMySpec` directly. A
  harness and a server that classify files differently produce a requirement
  graph matching neither checkout, so there is one copy of that code and this
  calls it.

  ## Deps

  Wider than it should be. Everything this needs from the domain —
  `Files.Scanner`, `Compile`, `Tests`, `BddSpecs.Spex`,
  `StaticAnalysis.CredoRun`, `Paths` — sits inside the single `CodeMySpec`
  boundary, so depending on any of it means depending on all of it. Narrowing
  this is a boundary-splitting job on the domain side, not something to fake
  from here.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CmsHarness.Channel,
      CodeMySpec,
      # `ToolIndex.carried/1`, the one list of direct tools an agent carries.
      CodeMySpec.Agents,
      CodeMySpec.Analysis,
      CodeMySpec.BddSpecs,
      CodeMySpec.BootVersion,
      CodeMySpec.CodeMode,
      CodeMySpec.Compile,
      CodeMySpec.Environments,
      CodeMySpec.Files,
      CodeMySpec.Generators,
      # `Hooks.PreToolUse.route_command/4`: an in-app agent's `mix test` is
      # routed the way a Claude Code agent's is.
      CodeMySpec.Hooks,
      # `CmsHarness.Application` installs the harness's log handler.
      CodeMySpec.Logging,
      # `cms migrate` (`CmsHarness.Migrate`) — a separate one-shot boot, not
      # the harness.
      CodeMySpec.Migration,
      CodeMySpec.Users.Scope,
      CodeMySpec.LocalScope,
      CodeMySpec.Paths,
      CodeMySpec.Permissions,
      CodeMySpec.Projects,
      # The three disk operations a promotion performs. The gate stays on the
      # server because it reads the database; `Steps` runs where the checkout
      # is, which is here — see `CodeMySpec.Promotion.Runner`.
      CodeMySpec.Promotion,
      CodeMySpec.RecordingLock,
      CodeMySpec.StaticAnalysis,
      CodeMySpec.Tests,
      CodeMySpec.Utils,
      CodeMySpec.WorkingCopies,
      CodeMySpec.Workspaces
    ],
    exports: :all
end
