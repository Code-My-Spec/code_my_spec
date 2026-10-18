defmodule CodeMySpec.AgentPerformance.Tools.AgentPerformanceReport do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.AgentPerformance
  alias CodeMySpec.Stories

  @impl true
  def name, do: "agent_performance_report"

  @impl true
  def description do
    """
    The agent performance page as Markdown: the week's rates against last
    week's, what to change first, and the breakdowns behind them. For an agent
    to read and draft an improvement plan from (John, 2026-10-15).
    """
  end

  @impl true
  def params do
    %{
      working_copy_id: {:meta, :string, [description: "Narrow to one working copy (team)."]},
      story_number: {:meta, :integer, [description: "Narrow to one story."]},
      agent_id: {:meta, :string, [description: "Narrow to one agent."]}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, filter} <- filter(scope, params) do
      {:ok, AgentPerformance.report(scope, filter)}
    else
      {:error, reason} -> {:error, "Report not read: #{inspect(reason)}"}
    end
  end

  defp filter(scope, params) do
    with {:ok, story_filter} <- story(scope, params[:story_number]) do
      {:ok,
       %{}
       |> put(:working_copy_id, params[:working_copy_id])
       |> put(:agent_id, params[:agent_id])
       |> Map.merge(story_filter)}
    end
  end

  defp story(_scope, nil), do: {:ok, %{}}

  defp story(scope, number) do
    case Stories.fetch_story_by_number(scope, number) do
      {:ok, story} -> {:ok, %{story_id: story.id}}
      {:error, :story_not_found} -> {:error, "no story #{number} in this project"}
    end
  end

  defp put(filter, _key, nil), do: filter
  defp put(filter, _key, ""), do: filter
  defp put(filter, key, value), do: Map.put(filter, key, value)
end
