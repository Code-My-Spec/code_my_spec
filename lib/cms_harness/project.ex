defmodule CmsHarness.Project do
  @moduledoc """
  One served working copy's connection to the server: the channel client that
  holds it and dispatches what the server asks to the agents, the app and the
  scanner, plus the file watcher and the analysis queue beside it. Started per
  copy under `CmsHarness.Copy.Supervisor` once the copy is served.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CmsHarness,
      CmsHarness.Attachments,
      CmsHarness.Agents,
      CmsHarness.Channel,
      CodeMySpec.BootVersion,
      CodeMySpec.ExecutionContexts,
      CodeMySpec.Files,
      CodeMySpec.Paths,
      # The three disk operations a promotion performs. The gate stays on the
      # server because it reads the database; `Steps` runs where the checkout
      # is, which is here — see `CodeMySpec.Promotion.Runner`.
      CodeMySpec.Promotion,
      CodeMySpec.Utils
    ],
    exports: :all
end
