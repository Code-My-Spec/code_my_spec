defmodule CmsHarness do
  @moduledoc """
  The light harness: the half of CodeMySpec that owns a disk.

  It watches a working copy, classifies what it finds, runs analyzers against
  it, and reports the conclusions up a channel to the server. It holds no
  database — no Repo, no schemas, no migrations — and that absence is the
  design rather than an unfinished piece of it. The server owns the model; this
  owns the bytes. Wanting a Repo in here is the signal that something belongs
  on the server instead.

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
      CodeMySpec,
      CodeMySpec.BootVersion,
      CodeMySpec.CodeMode,
      CodeMySpec.Environments,
      CodeMySpec.Paths,
      CodeMySpec.RecordingLock
    ],
    exports: :all
end
