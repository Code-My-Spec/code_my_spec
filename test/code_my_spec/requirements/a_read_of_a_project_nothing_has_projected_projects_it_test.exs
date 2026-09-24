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
  alias CodeMySpec.Requirements.StoryExecution
  alias CodeMySpec.Users.Scope
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    previous = %{
      projection: Application.get_env(:code_my_spec, :graph_shadow_projection, false),
      source: Application.get_env(:code_my_spec, :graph_event_is_source, false)
    }

    Application.put_env(:code_my_spec, :graph_event_is_source, true)

    on_exit(fn ->
      Fixtures.stop_graph_watchers()
      Application.put_env(:code_my_spec, :graph_shadow_projection, previous.projection)
      Application.put_env(:code_my_spec, :graph_event_is_source, previous.source)
    end)

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
      Application.put_env(:code_my_spec, :graph_shadow_projection, true)

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

    test "a read of an empty graph is told there is no graph, not a finished project",
         %{scope: %Scope{} = scope} do
      # The projector disabled: the event path serves, and nothing can write it.
      Application.put_env(:code_my_spec, :graph_shadow_projection, false)

      {:ok, _component} =
        Components.create_component(scope, %{
          name: "Ledger",
          type: "context",
          module_name: "Ledger",
          description: "a project nobody can project"
        })

      unproject(scope)
      result = StoryExecution.read(scope)

      assert result.status == :complete or result.status == :unavailable

      refute result.reason =~ "All requirements satisfied",
             "an empty graph read as a finished project: #{inspect(result.reason)}"

      assert result.reason =~ "No requirement graph yet", inspect(result.reason)
    end
  end
end
