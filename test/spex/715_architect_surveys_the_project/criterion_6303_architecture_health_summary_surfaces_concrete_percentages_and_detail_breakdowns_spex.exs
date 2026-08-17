defmodule CodeMySpecSpex.Story715.Criterion6303Spex do
  @moduledoc """
  Story 715 — Architect surveys the project
  Criterion 6303 — architecture_health_summary surfaces concrete percentages and detail breakdowns.

  When the project has mixed component coverage — at least one entry
  component with a linked story, at least one dependency component
  reached transitively, and at least one orphan context —
  `architecture_health_summary` returns a JSON payload that includes
  numeric percentages for `story_coverage_percentage`,
  `orphaned_percentage`, `coverage_score`, `dependency_score`, and
  `overall_score`, alongside detail breakdowns for missing references,
  high-fan-out components, and circular dependencies.

  Surface: `ArchitectureHealthSummary` MCP tool.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Components.Tools.ArchitectureHealthSummary

  import CodeMySpecSpex.GraphGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "architecture_health_summary surfaces concrete percentages and detail breakdowns" do
    scenario "architecture_health_summary surfaces concrete percentages and detail breakdowns" do
      given_ :story_with_liveview_surface
      given_ :orphan_component

      when_ "the agent calls architecture_health_summary", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = ArchitectureHealthSummary.execute(%{}, frame)
        {:ok, Map.put(context, :body, response_text(response))}
      end

      then_ "the response carries the five concrete percentage keys", context do
        for key <-
              ~w(story_coverage_percentage orphaned_percentage coverage_score dependency_score overall_score) do
          assert context.body =~ key,
                 "expected `#{key}` in health summary, got:\n#{context.body}"
        end

        {:ok, context}
      end

      and_ "each percentage is a numeric value", context do
        for key <-
              ~w(story_coverage_percentage orphaned_percentage coverage_score dependency_score overall_score) do
          assert context.body =~ ~r/"#{key}":\s*\d+(\.\d+)?/,
                 "expected `#{key}` to be a numeric value, got:\n#{context.body}"
        end

        {:ok, context}
      end

      and_ "the response includes detail breakdowns for dependency issues", context do
        for key <- ~w(missing_references high_fan_out_components circular_dependencies) do
          assert context.body =~ key,
                 "expected dependency_issues.#{key} in health summary, got:\n#{context.body}"
        end

        {:ok, context}
      end
    end
  end
end
