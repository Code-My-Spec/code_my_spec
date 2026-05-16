defmodule CodeMySpecSpex.Story715.Criterion6302Spex do
  @moduledoc """
  Story 715 — Architect surveys the project
  Criterion 6302 — show_architecture_overview groups components under their parent context headers.

  When a context component has at least one child component,
  `show_architecture_overview` returns markdown text whose `# Architecture
  Overview` document includes the context as a section and lists the
  child under that section.

  Surface: `ShowArchitectureOverview` MCP tool, backed by
  `Architecture.OverviewProjector`.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Architecture.Tools.ShowArchitectureOverview

  import CodeMySpecSpex.GraphGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "show_architecture_overview renders markdown grouped by parent context via OverviewProjector" do
    scenario "show_architecture_overview groups components under their parent context headers" do
      given_ :context_with_three_children

      when_ "the agent calls show_architecture_overview", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = ShowArchitectureOverview.execute(%{}, frame)
        {:ok, Map.put(context, :body, response_text(response))}
      end

      then_ "the response begins with the Architecture Overview title", context do
        assert context.body =~ ~r/^#\s+Architecture Overview/m,
               "expected overview title, got:\n#{context.body}"

        {:ok, context}
      end

      and_ "the context's name appears as a section header", context do
        assert context.body =~ ~r/^##\s+Reservations/m,
               "expected `## Reservations` section header, got:\n#{context.body}"

        {:ok, context}
      end

      and_ "the child components appear under the context's section", context do
        # OverviewProjector renders children under the context header using
        # short names (the last segment of the module path), not fully
        # qualified module names. The grouping invariant — children under
        # the context — is what this assertion pins.
        assert context.body =~ ~r/^###\s+Booking$/m,
               "expected child `Booking` (short name) listed under Reservations, got:\n#{context.body}"

        assert context.body =~ ~r/^###\s+BookingRepo$/m,
               "expected child `BookingRepo` listed under Reservations, got:\n#{context.body}"

        {:ok, context}
      end
    end
  end
end
