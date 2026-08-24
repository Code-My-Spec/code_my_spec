defmodule CodeMySpecSpex do
  @moduledoc false
  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Environments,
      CodeMySpec.McpServers,
      CodeMySpec.RecordingLock,
      CodeMySpec.TempFile,
      CodeMySpecSpex.Fixtures,
      # The harness-side counterpart to `Fixtures`: spex that are about what
      # a machine did have to drive the harness, and may not reference
      # `CmsHarness` to do it.
      CmsHarnessTest,
      CodeMySpecWeb,
      CodeMySpecLocalWeb
    ]
end
