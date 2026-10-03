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
      # Story 1086's criteria 1765/1766 call `Activity.record/4,5` and
      # `.list_for_resource/2` directly — the module under test (an
      # append-only log has no page of its own to assert "an entry exists"
      # or "nothing erases it" through), same reasoning as `AgentTasks` and
      # `Promotion` below.
      CodeMySpec.Activity,
      CodeMySpec.Agents,
      # Story 1108, criterion 4657 calls `QaStory.command/2` directly — it is
      # the module under test (the prompt `start_task` hands a QA agent), the
      # same reason `CodeMySpec.McpServers` is a dep for spex that call a tool
      # module's `execute/2` directly rather than going in behind it.
      CodeMySpec.AgentTasks,
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
      # Story 1108, criterion 4663 calls `Promotion.Runner.restart/3`
      # directly — it is the module under test (does a promote's restart
      # reach the harness through the same channel verb every other
      # working copy's app already uses), the same reasoning as
      # `CodeMySpec.AgentTasks` above.
      CodeMySpec.Promotion,
      CodeMySpec.Problems,
      # Story 1089's criterion 1848 calls `Qa.QaAttempts.list/2` directly to
      # re-read the attempt's own row after submission — the module under
      # test (does the evidence persist, not just appear in the one-time
      # tool response), same reasoning as `CodeMySpec.AgentTasks` and
      # `CodeMySpec.Promotion` above.
      CodeMySpec.Qa,
      # Story 1116's `ClickHouseCassetteHelpers.configure!/2` writes real
      # `ProjectSecrets` rows and `stub_rows_by_username/1` stubs
      # `Observability.ClickHouseClient` — the module under test for
      # every criterion in that story, the same reasoning as
      # `CodeMySpec.AgentTasks` and `CodeMySpec.Promotion` above.
      CodeMySpec.Observability,
      CodeMySpec.ProjectSecrets,
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
      # Criteria 1586/1587 call `PreviewTunnel.ensure/1` and `PreviewAddress.host/1`
      # directly — `PreviewTunnel` is the module under test (this story's own
      # declared component), the same reasoning as `CodeMySpec.AgentTasks` and
      # `CodeMySpec.Promotion` above. A second onboarding run against a second
      # real root is what production does for the sibling copy; standing one up
      # inside one spec's sandboxed environment is infrastructure this suite
      # does not yet have (see that spec's own moduledoc).
      CodeMySpec.Workspaces,
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
