defmodule CodeMySpec.McpServers.Bootstrap.Tools.ListProjects do
  @moduledoc """
  List available CodeMySpec projects.

  Returns the projects accessible to the authenticated user. Use the
  project_id from the results to call `init_project` and link your
  working directory.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Auth.OAuthClient

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case fetch_projects() do
      {:ok, projects} ->
        {:reply, format_response(projects), frame}

      {:error, reason} ->
        response = Response.tool() |> Response.error("Failed to list projects: #{reason}")
        {:reply, response, frame}
    end
  end

  defp fetch_projects do
    with {:ok, token} <- OAuthClient.get_token() do
      server_url = OAuthClient.get_server_url()
      url = "#{server_url}/api/projects"
      headers = [{"authorization", "Bearer #{token}"}]

      case Req.get(url, headers: headers) do
        {:ok, %{status: 200, body: %{"projects" => projects}}} -> {:ok, projects}
        {:ok, %{status: status}} -> {:error, "Server returned #{status}"}
        {:error, reason} -> {:error, "Failed to reach server: #{inspect(reason)}"}
      end
    end
  end

  defp format_response(projects) do
    lines =
      Enum.map_join(projects, "\n", fn p ->
        "- **#{p["name"]}** (`#{p["id"]}`)" <>
          if(p["description"], do: " — #{p["description"]}", else: "")
      end)

    text =
      if projects == [] do
        "No projects found. Create a project on the CodeMySpec web app first."
      else
        "# Available Projects\n\n#{lines}\n\nUse `init_project` with the project_id to link your working directory."
      end

    Response.tool()
    |> Response.text(text)
    |> Map.put(:structured_content, %{
      projects: Enum.map(projects, fn p ->
        %{id: p["id"], name: p["name"], description: p["description"]}
      end)
    })
  end
end
