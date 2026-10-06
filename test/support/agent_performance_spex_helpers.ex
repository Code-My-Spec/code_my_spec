defmodule CodeMySpecSpex.AgentPerformanceHelpers do
  @moduledoc """
  Path builders for the agent-performance report (story 1092).

  Twenty criteria share these two paths -- the same reason
  `WorkingCopyHelpers` and `PromotionHelpers` exist for their own surfaces.
  """

  @doc "The summary page: headline numbers per team and per role."
  @spec index_path(map()) :: String.t()
  def index_path(context), do: "/app/projects/#{context.project.id}/agent-performance"

  @doc "One agent's detail page, reached from the index."
  @spec show_path(map(), %{id: String.t()}) :: String.t()
  def show_path(context, %{id: agent_id}),
    do: "/app/projects/#{context.project.id}/agent-performance/#{agent_id}"
end
