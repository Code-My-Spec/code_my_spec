defmodule CodeMySpec.McpServers.Issues.Tools.CreateIssue do
  @moduledoc """
  Record an issue against the project (`scope: app`) or against
  CodeMySpec itself (`scope: framework`).

  If you encounter undocumented config, a looping hook, a tool error,
  or contradictory prompts inside CodeMySpec, your FIRST call is
  `create_issue` with `scope: framework` — before asking the human
  operator and before working around the problem. The framework is
  the system you are operating inside; friction with it is a
  first-class issue, not a question to escalate or a workaround to
  invent.

  Trigger examples (use `scope: framework`):

  - Confusing or contradictory prompts/instructions
  - Looping stop hooks or stuck workflows
  - Errors from tools or MCP servers
  - Missing, broken, or poorly documented tools
  - Suggestions for improvements to the system

  For project-side bugs and feature gaps (the app under development,
  not CodeMySpec), use `scope: app` (the default).

  Issues land as `incoming` and are triaged by the human operator. Be
  specific in your description — include the exact error message, what
  you were doing, and what you expected to happen.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Issues
  alias CodeMySpec.McpServers.Issues.IssuesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :title, :string, required: true, doc: "Short issue title"

    field :severity, :string,
      required: true,
      doc: "Issue severity: critical, high, medium, low, or info"

    field :description, :string,
      required: true,
      doc: "Detailed description of the issue including steps to reproduce if applicable"

    field :scope, :string, doc: "Issue scope: app (default), qa, docs, or framework"

    field :story_id, :integer, doc: "Related user story ID, if applicable"

    field :source_path, :string, doc: "File path where the issue was found, if applicable"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         attrs <- build_attrs(params),
         {:ok, issue} <- create(scope, attrs) do
      {:reply, IssuesMapper.issue_created_response(issue), frame}
    else
      {:error, changeset = %Ecto.Changeset{}} ->
        {:reply, IssuesMapper.validation_error(changeset), frame}

      {:error, reason} ->
        {:reply, IssuesMapper.error(reason), frame}
    end
  end

  # Every scope writes the same way. Framework issues used to be special —
  # posted over HTTP to the server because the tools ran on a developer's
  # machine and the server was elsewhere. The tools run on the server now, so
  # that path had the server authenticating to itself as a CLI, with a
  # credential only a CLI has, and it answered `not_authenticated` for every
  # framework issue an agent tried to file.
  defp create(scope, attrs), do: Issues.create_issue(scope, attrs)

  defp build_attrs(params) do
    params
    |> Map.put(:status, :incoming)
    |> maybe_atomize(:severity)
    |> maybe_atomize(:scope)
  end

  defp maybe_atomize(map, key) do
    case Map.get(map, key) do
      val when is_binary(val) ->
        try do
          Map.put(map, key, String.to_existing_atom(val))
        rescue
          ArgumentError -> map
        end

      _ ->
        map
    end
  end
end
