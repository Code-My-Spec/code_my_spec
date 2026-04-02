defmodule CodeMySpec.McpServers.Issues.Tools.CreateExternalIssue do
  @moduledoc """
  Report an issue with the CodeMySpec platform from an external agent.

  Use this tool when your CodeMySpec instance encounters problems with the
  platform itself — generation errors, incorrect code output, broken workflows,
  or suggestions for improving the system.

  Issues are routed to the CodeMySpec platform project and will be triaged
  by the platform team.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Issues
  alias CodeMySpec.McpServers.Issues.IssuesMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Projects

  schema do
    field :title, :string, required: true, doc: "Short issue title"

    field :severity, :string,
      required: true,
      doc: "Issue severity: critical, high, medium, low, or info"

    field :description, :string,
      required: true,
      doc: "Detailed description of the issue including steps to reproduce if applicable"

    field :scope, :string,
      doc: "Issue scope: app (default), qa, or docs"

    field :source_path, :string,
      doc: "File path where the issue was found, if applicable"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, base_scope} <- Validators.validate_scope(frame),
         {:ok, scope} <- resolve_platform_scope(base_scope),
         attrs <- build_attrs(params),
         {:ok, issue} <- Issues.create_issue(scope, attrs) do
      {:reply, IssuesMapper.issue_created_response(issue), frame}
    else
      {:error, :platform_project_not_configured} ->
        {:reply, IssuesMapper.error("Platform project not configured"), frame}

      {:error, :platform_project_not_found} ->
        {:reply, IssuesMapper.error("Platform project not found"), frame}

      {:error, changeset = %Ecto.Changeset{}} ->
        {:reply, IssuesMapper.validation_error(changeset), frame}

      {:error, reason} ->
        {:reply, IssuesMapper.error(reason), frame}
    end
  end

  defp resolve_platform_scope(base_scope) do
    case Projects.get_platform_project() do
      {:ok, project} ->
        scope = %{base_scope | active_project: project, active_project_id: project.id}
        {:ok, scope}

      {:error, :not_configured} ->
        {:error, :platform_project_not_configured}

      {:error, :not_found} ->
        {:error, :platform_project_not_found}
    end
  end

  defp build_attrs(params) do
    params
    |> Map.put(:status, :incoming)
    |> Map.put(:source, :external_agent)
    |> maybe_atomize(:severity)
    |> maybe_atomize(:scope)
  end

  defp maybe_atomize(map, key) do
    case Map.get(map, key) do
      val when is_binary(val) -> Map.put(map, key, val |> String.downcase() |> String.to_existing_atom())
      _ -> map
    end
  end
end
