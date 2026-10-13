defmodule CodeMySpecTest do
  @moduledoc false

  # These are exported so `CodeMySpecSpex.Fixtures` can install and drive them.
  # That does not open them to spex: Boundary needs the dep *and* the export,
  # and `CodeMySpecSpex` carries no `CodeMySpecTest` dep — reaching into test
  # support is the bridge's job, not a criterion's.
  #
  # Boundary flags cross-boundary *calls*, not module references, which is why
  # naming a module in config and handing it to `start_supervised!` has always
  # passed while `FakeWorkspaceRunner.put_serving/1` from a spex did not.
  #
  use Boundary,
    top_level?: true,
    # `CmsHarnessTest.Machine` owns "make sure the agent tree exists". The
    # in-process transport starts real agents through it, and a second copy of
    # that setup is how one test's supervisor ended up holding another test's
    # agents.
    # `CodeMySpec.McpServers` because `InVmMcpTransport` stands in for the wire
    # between the harness and the server, which means touching both sides of it.
    # That is exactly why it lives here rather than beside the real transport:
    # `CmsHarness` may not reference the MCP layer, and a test double for a wire
    # has to.
    # `CodeMySpec.Requirements` because `GraphHelpers` has to start a watcher
    # and settle it. Observing that the graph moved is test support's job by
    # construction: the alternative is every test re-deriving the recipe from
    # `GraphWatcher`, `GraphInputs` and the recording transport separately,
    # which is where it lived before and why nobody used it.
    deps: [
      CmsHarness,
      CmsHarnessTest,
      CodeMySpec,
      CodeMySpec.Agents,
      CodeMySpec.Embeddings,
      CodeMySpec.McpServers,
      CodeMySpec.PromotionQueue,
      CodeMySpec.Requirements,
      CodeMySpec.Requirements.GraphInputs,
      CodeMySpec.TempFile,
      CodeMySpec.UserPreferences,
      CodeMySpec.Users,
      CodeMySpec.Users.Scope,
      CodeMySpec.Workspaces
    ],
    # `TurnEventRelay` is exported for the same reason the other two are:
    # `CodeMySpecSpex.Fixtures` installs it on a criterion's behalf. It is the
    # seam that lets an in-process agent's turn events reach the server at all.
    #
    # `RecordingAgentTransport` for criterion 1376 (story 1046): the promoted
    # agent correction (`Promotion.tell_the_agent/4`) is a fire-and-forget
    # message dispatch with no other observable surface — no DB row, no MCP
    # response. `CodeMySpecSpex.Fixtures` installs it and hands back the
    # dispatched message the same way it does the other two fakes here.
    #
    # `RecordingEmbeddingServing` for the same reason: `CodeMySpecSpex.Fixtures`
    # installs it and drives it (listen, reset, pause/release, fail, model) on
    # a criterion's behalf — story 1087's embeddings-airtight work.
    exports: [
      AgentPresence,
      FakeWorkspaceRunner,
      HexTarballFixtures,
      RecordingAgentTransport,
      RecordingEmbeddingServing,
      TurnEventRelay,
      WorkspaceWatchers
    ]
end
