defmodule CodeMySpecSpex do
  @moduledoc false
  use Boundary,
    top_level?: true,
    deps: [
      # `f2ff4147`: the block below (`Agents` through `WorkingCopies`) is what
      # spex actually reach today, measured off a real compiler sweep once the
      # leg stopped silently discarding its findings (see `866ba007b`,
      # `fa6d31bf`). None of this is a new crossing — every one of these was
      # already being called from a spex file; only the declaration was stale.
      CodeMySpec.Agents,
      CodeMySpec.Analysis,
      CodeMySpec.Conversations,
      CodeMySpec.EpicDispatch,
      CodeMySpec.Environments,
      CodeMySpec.Faults,
      CodeMySpec.Hooks,
      # "The agent cannot be reached" is external system state, and the shaper
      # behaviour is the only seam the application offers for standing the
      # model down. A spec about what onboarding does when the model is
      # unavailable has to be able to make it unavailable.
      CodeMySpec.Intake,
      CodeMySpec.Issues,
      CodeMySpec.McpServers,
      # A zero-dep leaf exporting only path constants. `ProjectBuilder` has to
      # write where the scanner looks, and hardcoding `.code_my_spec/spec`
      # beside the module that owns it is how a fixture quietly stops being
      # synced when the convention moves.
      CodeMySpec.Paths,
      CodeMySpec.Problems,
      CodeMySpec.RecordingLock,
      # A submodule of `Requirements`, not its own boundary — `GraphInputs`
      # alone cannot be named as a dep (Boundary classifies by the nearest
      # enclosing top-level boundary), and `Requirements` exports it.
      # `Fixtures.watch_graph/1` and `settle_graph/1` use it to publish and
      # subscribe on the graph's own topic.
      CodeMySpec.Requirements,
      CodeMySpec.ScreenState,
      CodeMySpec.Stories,
      CodeMySpec.TempFile,
      CodeMySpec.Utils,
      CodeMySpec.WorkingCopies,
      CodeMySpecSpex.Fixtures,
      # Recorded analyzer output attached to a spex's environment.
      CodeMySpecSpex.RecordedAnalysis,
      # The harness-side counterpart to `Fixtures`: spex that are about what
      # a machine did have to drive the harness, and may not reference
      # `CmsHarness` to do it.
      CmsHarnessTest,
      CodeMySpecWeb,
      CodeMySpecLocalWeb
    ]
end
