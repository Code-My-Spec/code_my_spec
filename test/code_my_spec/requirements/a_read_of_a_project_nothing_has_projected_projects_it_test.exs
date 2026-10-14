defmodule CodeMySpec.Requirements.AReadOfAProjectNothingHasProjectedProjectsItTest do
  @moduledoc """
  A project nothing has ever projected is projected by the first read of it,
  and until then a read says there is no graph rather than a finished one.

  Metric Flow, 2026-09-23: onboarded and healthy, 182 components, 53 stories,
  27 failing tests, 3,480 marks queued and zero rows. Writers start with an
  agent or at boot for continuous projects, and nobody starts an agent on a
  project whose `get_next_requirement` says "All requirements satisfied" —
  which is what zero rows said. Two fixes, one for each half.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpec.Components
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Users.Scope
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    on_exit(fn -> Fixtures.stop_graph_watchers() end)
    :ok
  end

  # The rows the setup and the announces left, and the writers that wrote them:
  # a project nothing has projected has neither.
  defp unproject(%Scope{} = scope) do
    Fixtures.stop_graph_watchers()
    Fixtures.forget_projection(scope)
  end

  describe "with the event path serving" do
    test "a read projects the project and answers from the rows", %{scope: %Scope{} = scope} do
      {:ok, _component} =
        Components.create_component(scope, %{
          name: "Ledger",
          type: "context",
          module_name: "Ledger",
          description: "a project nobody has projected"
        })

      # As Metric Flow stood: entities, no rows, no writer.
      unproject(scope)

      refute Requirements.projected?(scope),
             "the premise did not hold: rows exist before any read"

      actionable = RequirementGraph.next_actionable(scope)

      assert Requirements.projected?(scope),
             """
             A read of a project nothing had projected wrote nothing and served
             nothing.

             Writers start with an agent or at boot for continuous projects. A
             project with a live harness and no agent has neither, and its
             marks queue forever — 3,480 on Metric Flow — while every read is
             served an empty graph.
             """

      assert actionable != [],
             "the rows were projected and the read still answered from before them"
    end
  end
end
