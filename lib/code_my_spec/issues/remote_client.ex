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
    token = opts[:token] || get_token!()

    Req.new(
      base_url: get_base_url(),
      headers: build_headers(token, scope),
      decode_json: [keys: :strings],
      retry: :transient,
      max_retries: 3
    )
    |> maybe_plug(opts)
  end

  defp get_token! do
    {:ok, token} = OAuthClient.get_token()
    token
  end

  # ---------------------------------------------------------------------------
  # Read operations
  # ---------------------------------------------------------------------------

  def list_accepted_issues(%Scope{} = scope, opts \\ []) do
    client = new(scope, opts)

    {:ok, %{status: 200, body: body}} =
      Req.get(client, url: "/api/issues", params: [status: "accepted"])

    {:ok, Enum.map(body["data"], &deserialize_issue/1)}
  end

  # ---------------------------------------------------------------------------
  # Mutation operations
  # ---------------------------------------------------------------------------

  def update_issue(%Scope{} = scope, issue_id, attrs, opts \\ []) do
    client = new(scope, opts)

    case Req.put(client,
           url: "/api/issues/#{issue_id}",
           json: %{issue: stringify_attrs(attrs)}
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, deserialize_issue(body["data"])}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: 422, body: body}} ->
        {:error, body}
    end
  end

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
    Application.get_env(:code_my_spec, :base_url, "https://dev.codemyspec.com")
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
