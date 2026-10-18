defmodule CodeMySpec.Bootstrap.Tools.ListProjects do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.Bootstrap.Tools.Responses, as: BootstrapMapper

  @impl true
  def name, do: "list_projects"

  @impl true
  def description do
    """
    List available CodeMySpec projects.

    Returns the projects accessible to the authenticated user. Use the
    project_id from the results to call `init_project` and link your
    working directory.
    """
  end

  @impl true
  def params do
    %{}
  end

  @impl true
  def call(_params, _context) do
    case fetch_projects() do
      {:ok, projects} ->
        format_response(projects)

      {:error, reason} when reason in [:not_authenticated, :needs_authentication] ->
        BootstrapMapper.not_authenticated_error()

      {:error, reason} ->
        response = {:error, "Failed to list projects: #{reason}"}
        response
    end
  end

  # `projects` is already a list of plain, string-keyed maps decoded straight
  # from the server's own JSON response -- nothing to row-map here, unlike
  # every other tool in this fix, which starts from an Ecto struct.
  @impl true
  def script_result(_params, _frame) do
    case fetch_projects() do
      {:ok, projects} ->
        {:ok, projects}

      {:error, reason} when reason in [:not_authenticated, :needs_authentication] ->
        {:error, "Not authenticated. Run init_project to authenticate first."}

      {:error, reason} ->
        {:error, "Failed to list projects: #{reason}"}
    end
  end

  defp fetch_projects do
    with {:ok, token} <- OAuthClient.get_token() do
      server_url = OAuthClient.get_server_url()
      url = "#{server_url}/api/projects"
      headers = [{"authorization", "Bearer #{token}"}]

      case Req.get(url, [headers: headers] ++ req_options()) do
        {:ok, %{status: 200, body: %{"projects" => projects}}} -> {:ok, projects}
        {:ok, %{status: status}} -> {:error, "Server returned #{status}"}
        {:error, reason} -> {:error, "Failed to reach server: #{inspect(reason)}"}
      end
    end
  end

  # Every other outbound Req client in this app is pinned to `Req.Test` in
  # config/test.exs so an unstubbed test call raises instead of reaching the
  # real server -- this one was not, and a token present with no stub would
  # have made a live request to codemyspec.com from the unit suite.
  defp req_options, do: Application.get_env(:code_my_spec, __MODULE__, [])

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

    {:ok, text}
  end
end
