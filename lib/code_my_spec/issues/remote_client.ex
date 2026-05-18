defmodule CodeMySpec.Issues.RemoteClient do
  @moduledoc """
  HTTP client for the remote Issues API.

  Mirrors the shape of the other remote clients (`Stories`, `Personas`,
  `BddRules`, `Questions`): public functions take a `%Scope{}`, build the
  `Req` client internally, and return deserialized values (`%Issue{}` or
  `[%Issue{}]`) — never raw `Req.Response` tuples. Used only by
  `Issues.RemoteSync` and `Issues.sync_resolution_to_remote/2`; not a
  swap-in repository implementation.
  """

  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Users.Scope

  # ---------------------------------------------------------------------------
  # Client construction
  # ---------------------------------------------------------------------------

  def new(%Scope{} = scope, opts \\ []) do
    with {:ok, token} <- token_for(opts) do
      client =
        Req.new(
          base_url: get_base_url(),
          headers: build_headers(token, scope),
          decode_json: [keys: :strings],
          retry: :transient,
          max_retries: 3
        )
        |> maybe_plug(opts)

      {:ok, client}
    end
  end

  defp token_for(opts) do
    case opts[:token] do
      nil -> OAuthClient.get_token()
      token -> {:ok, token}
    end
  end

  # ---------------------------------------------------------------------------
  # Read operations
  # ---------------------------------------------------------------------------

  def list_accepted_issues(%Scope{} = scope, opts \\ []) do
    with {:ok, client} <- new(scope, opts),
         {:ok, response} <- Req.get(client, url: "/api/issues", params: [status: "accepted"]) do
      handle_list_response(response)
    end
  end

  @doc """
  Lists incoming issues across all scopes for the active project.

  Used by `Issues.pull_incoming_from_remote/1` at the start of every
  triage task to ensure the local DB reflects the server's current
  incoming-issue view before the agent begins triage. The server
  honors per-project access via the `x-project-id` header set in
  `build_headers/2`, so the response is naturally project-scoped.
  """
  def list_incoming_issues(%Scope{} = scope, opts \\ []) do
    with {:ok, client} <- new(scope, opts),
         {:ok, response} <- Req.get(client, url: "/api/issues", params: [status: "incoming"]) do
      handle_list_response(response)
    end
  end

  defp handle_list_response(%{status: 200, body: body}),
    do: {:ok, Enum.map(body["data"], &deserialize_issue/1)}

  defp handle_list_response(%{status: status, body: body}),
    do: {:error, {:unexpected_status, status, body}}

  # ---------------------------------------------------------------------------
  # Mutation operations
  # ---------------------------------------------------------------------------

  @doc """
  Creates an issue on the remote API.

  Used by the local CLI's `create_issue` MCP tool when called with
  `scope: framework`. Framework-scoped friction (looping hooks, contradictory
  prompts, tool errors) lives on the CodeMySpec server, never in the local
  CLI's DB; this is the one and only path for framework writes.

  Returns `{:ok, %Issue{}}` on 201, `{:error, {:validation, body}}` on 422,
  or `{:error, reason}` otherwise.
  """
  def create_issue(%Scope{} = scope, attrs, opts \\ []) do
    with {:ok, client} <- new(scope, opts),
         {:ok, response} <-
           Req.post(client, url: "/api/issues", json: %{issue: stringify_attrs(attrs)}) do
      handle_create_response(response)
    end
  end

  defp handle_create_response(%{status: status, body: body}) when status in [200, 201],
    do: {:ok, deserialize_issue(body["data"])}

  defp handle_create_response(%{status: 422, body: body}), do: {:error, {:validation, body}}

  defp handle_create_response(%{status: status, body: body}),
    do: {:error, {:unexpected_status, status, body}}

  def update_issue(%Scope{} = scope, issue_id, attrs, opts \\ []) do
    with {:ok, client} <- new(scope, opts),
         {:ok, response} <-
           Req.put(client,
             url: "/api/issues/#{issue_id}",
             json: %{issue: stringify_attrs(attrs)}
           ) do
      handle_update_response(response)
    end
  end

  defp handle_update_response(%{status: 200, body: body}),
    do: {:ok, deserialize_issue(body["data"])}

  defp handle_update_response(%{status: 404}), do: {:error, :not_found}
  defp handle_update_response(%{status: 422, body: body}), do: {:error, {:validation, body}}

  defp handle_update_response(%{status: status, body: body}),
    do: {:error, {:unexpected_status, status, body}}

  # ---------------------------------------------------------------------------
  # Deserialization
  # ---------------------------------------------------------------------------

  def deserialize_issue(data) do
    %Issue{
      id: data["id"],
      title: data["title"],
      severity: parse_enum(data["severity"]),
      scope: parse_enum(data["scope"]),
      description: data["description"],
      source: data["source"],
      status: parse_enum(data["status"]),
      resolution: data["resolution"],
      story_id: data["story_id"],
      source_path: data["source_path"],
      project_id: data["project_id"],
      account_id: data["account_id"],
      inserted_at: parse_datetime(data["inserted_at"]),
      updated_at: parse_datetime(data["updated_at"])
    }
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp build_headers(token, %Scope{active_project_id: pid}) when is_binary(pid) do
    [authorization: "Bearer #{token}", "x-project-id": pid]
  end

  defp build_headers(token, _scope) do
    [authorization: "Bearer #{token}"]
  end

  defp get_base_url do
    Application.get_env(:code_my_spec, :base_url, "https://codemyspec.com")
  end

  defp maybe_plug(req, opts) do
    case Keyword.get(opts, :plug) do
      nil -> req
      plug -> Req.merge(req, plug: plug)
    end
  end

  defp stringify_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp parse_enum(nil), do: nil
  defp parse_enum(val) when is_binary(val), do: String.to_existing_atom(val)

  defp parse_datetime(nil), do: nil

  defp parse_datetime(datetime_string) when is_binary(datetime_string) do
    case DateTime.from_iso8601(datetime_string) do
      {:ok, datetime, _offset} -> datetime
      {:error, _} -> nil
    end
  end
end
