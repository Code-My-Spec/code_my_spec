defmodule CodeMySpecWeb.ServerLive.Paths do
  @moduledoc """
  Where the servers pages live: in the project's console when the route names
  a project, at the account's `/app/servers` otherwise. The servers are the
  account's either way; only the frame differs.
  """

  @doc "The servers index for these route params; a server's page hangs off it."
  def base(%{"project_id" => project_id}) when is_binary(project_id),
    do: "/app/projects/#{project_id}/console/servers"

  def base(_params), do: "/app/servers"
end
