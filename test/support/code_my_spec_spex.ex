defmodule CodeMySpecSpex do
  @moduledoc false
  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Environments,
      # "The agent cannot be reached" is external system state, and the shaper
      # behaviour is the only seam the application offers for standing the
      # model down. A spec about what onboarding does when the model is
      # unavailable has to be able to make it unavailable.
      CodeMySpec.Intake,
      CodeMySpec.McpServers,
      # A zero-dep leaf exporting only path constants. `ProjectBuilder` has to
      # write where the scanner looks, and hardcoding `.code_my_spec/spec`
      # beside the module that owns it is how a fixture quietly stops being
      # synced when the convention moves.
      CodeMySpec.Paths,
      CodeMySpec.RecordingLock,
      CodeMySpec.TempFile,
      CodeMySpec.Utils,
      CodeMySpecSpex.Fixtures,
      # The harness-side counterpart to `Fixtures`: spex that are about what
      # a machine did have to drive the harness, and may not reference
      # `CmsHarness` to do it.
      CmsHarnessTest,
      CodeMySpecWeb,
      CodeMySpecLocalWeb
    ]
end
