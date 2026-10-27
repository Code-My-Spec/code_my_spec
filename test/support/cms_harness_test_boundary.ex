defmodule CmsHarnessTest do
  @moduledoc false
  # `CodeMySpec.TempFile` is a leaf boundary with no deps of its own, taken for
  # temp paths that two concurrently running suites cannot both pick. It is the
  # one thing here reaching outside the harness; when the harness moves to its
  # own repo this module goes with it, and a dozen lines of token generation
  # come along rather than the dependency.
  #
  # `Machine` and `HeldProvider` drive a real harness without referencing
  # `CmsHarness` directly, which a spex may not do (see `CodeMySpecSpex`'s own
  # boundary). `AnalysisResults`, `Projects`, `FakeServer`, `BlockingProject`
  # and `SlotHolder` are the same kind of facade, one per concern a story 839
  # criterion needs (waiting on a real result, a throwaway working copy, the
  # far side of the websocket, a compile step held open, a machine-wide slot
  # taken directly, Claude Code's own agent list for a terminal agent) — each
  # extracted because more than one spex needed it, per its own moduledoc.
  # `f2ff4147`: this list undercounted them for as long as the compiler leg
  # silently discarded its findings, so the export list never caught up with
  # what spex actually reaches. Anything not listed here is
  # genuinely internal to the harness's own unit tests.
  use Boundary,
    top_level?: true,
    deps: [
      CmsHarness,
      CmsHarness.Agents,
      CmsHarness.CopyTools,
      CmsHarness.Channel,
      CmsHarness.Project,
      CmsHarness.Supervisor,
      CodeMySpec.TempFile
    ],
    exports: [
      SetupFixture,
      Machine,
      LiveHarness,
      ConnectHeaders,
      HeldProvider,
      AnalysisResults,
      GateWait,
      Projects,
      FakeServer,
      HarnessOAuthFixture,
      BlockingProject,
      ClusteredProject,
      SlotHolder,
      AppInstanceHelpers,
      AttachmentRuntime,
      FakeAppInstanceRunner,
      ClaudeSessions
    ]
end
