defmodule CodeMySpec.Hooks do
  @moduledoc """
  Agent hook decisions, independent of who is serving them.

  A hook does two separable things: it *runs* something against a working copy,
  and it *decides* what the result means. Only the first needs a disk. The
  decision — blocking problems, configuration modes, session and task state,
  the stuck-detection and handoff rules — is a function of the database, and it
  is identical whether the request arrived at a developer's laptop, a sprite, or
  the server.

  This boundary is where the deciding half lives, so that every harness reaches
  the same verdict from the same inputs rather than each carrying a copy that
  drifts.

  ## Why its own boundary

  The decisions need `CodeMySpec.McpServers` for the formatting an agent reads
  (`RequirementsMapper` renders the block reason). `CodeMySpec` deliberately
  does not depend on `McpServers` — `McpServers` depends on `CodeMySpec` — so
  putting this in the domain boundary would close a cycle. A sibling top-level
  boundary that may depend on both, in the same shape as `McpServers` and
  `AgentHarness`, is the honest place for it.

  ## What does not live here

  Anything that shells out. Analyzer execution stays with whoever holds the
  working copy and the toolchain; this boundary is handed results, never a
  directory.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Agents,
      CodeMySpec.Analysis,
      CodeMySpec.Configurations,
      CodeMySpec.Conversations,
      CodeMySpec.Environments,
      CodeMySpec.FileEdits,
      CodeMySpec.McpServers,
      CodeMySpec.Notifications,
      CodeMySpec.Problems,
      CodeMySpec.Repo,
      CodeMySpec.Requirements,
      CodeMySpec.Sessions,
      CodeMySpec.Users,
      CodeMySpec.Validation
    ],
    exports: :all
end
