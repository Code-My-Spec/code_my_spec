defmodule CodeMySpecSpex.Story715.Criterion6311Spex do
  @moduledoc """
  Story 715 — Architect surveys the project
  Criterion 6311 — validate_dependency_graph reports detected cycles when the graph is cyclic.

  When two non-schema components have a cyclic dependency (A → B and
  B → A), `validate_dependency_graph` returns a failure response that
  names both components in the cycle.

  The cycle is set up via `Fixtures.dependency_fixture/3` because the
  proposal flow rejects non-schema cycles at validation time — the
  cycle this validator detects can only be reached by bypassing the
  proposal layer.

  Surface: `ValidateDependencyGraph` MCP tool, backed by
  `Components.validate_dependency_graph/1`.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Architecture.Tools.ValidateDependencyGraph
  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.GraphGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "validate_dependency_graph detects cycles between non-schema components" do
    scenario "validate_dependency_graph reports detected cycles when the graph is cyclic" do
      given_ :cross_context_dependency

      given_ "a reverse dependency closes the cycle between the two contexts", context do
        # cross_context_dependency seeds Stories → Users. Adding Users → Stories
        # via the dependency fixture closes the cycle. This bypasses Proposal
        # validation, which is intentional — the proposal layer would reject
        # this state, but the DB-level validator needs to detect it when it
        # exists.
        {:ok, _dep} =
          Fixtures.dependency_fixture(context.scope, context.users_context, context.stories_context)

        {:ok, context}
      end

      when_ "the agent calls validate_dependency_graph", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = ValidateDependencyGraph.execute(%{}, frame)
        {:ok, Map.put(context, :body, response_text(response))}
      end

      then_ "the response indicates a circular-dependency failure", context do
        assert context.body =~ ~r/circular|cycle/i,
               "expected response to flag circular dependencies, got:\n#{context.body}"

        {:ok, context}
      end

      and_ "the response names both contexts involved in the cycle", context do
        assert context.body =~ "Users",
               "expected Users in cycle report, got:\n#{context.body}"

        assert context.body =~ "Stories",
               "expected Stories in cycle report, got:\n#{context.body}"

        {:ok, context}
      end
    end
  end
end
