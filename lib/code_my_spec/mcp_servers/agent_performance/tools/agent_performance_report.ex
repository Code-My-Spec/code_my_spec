defmodule CodeMySpec.McpServers.AgentPerformance.Tools.AgentPerformanceReport do
  @moduledoc """
  The agent performance page as Markdown: the week's rates against last
  week's, what to change first, and the breakdowns behind them. For an agent
  to read and draft an improvement plan from (John, 2026-10-15).
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.AgentPerformance
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Utils.MapAccess
  alias CodeMySpec.Stories

  schema do
    field :working_copy_id, :string, description: "Narrow to one working copy (team)."
    field :story_number, :integer, description: "Narrow to one story."
    field :agent_id, :string, description: "Narrow to one agent."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         {:ok, filter} <- filter(scope, params) do
      {:reply, Response.tool() |> Response.text(AgentPerformance.report(scope, filter)), frame}
    else
      {:error, reason} ->
        {:reply, Response.tool() |> Response.error("Report not read: #{inspect(reason)}"), frame}
    end
  end

  defp filter(scope, params) do
    with {:ok, story_filter} <- story(scope, MapAccess.get(params, :story_number)) do
      {:ok,
       %{}
       |> put(:working_copy_id, MapAccess.get(params, :working_copy_id))
       |> put(:agent_id, MapAccess.get(params, :agent_id))
       |> Map.merge(story_filter)}
    end
  end

  defp story(_scope, nil), do: {:ok, %{}}

  defp story(scope, number) do
    case Stories.get_story_by_number(scope, number) do
      nil -> {:error, "no story #{number} in this project"}
      story -> {:ok, %{story_id: story.id}}
    end
  end

  defp put(filter, _key, nil), do: filter
  defp put(filter, _key, ""), do: filter
  defp put(filter, key, value), do: Map.put(filter, key, value)
end
