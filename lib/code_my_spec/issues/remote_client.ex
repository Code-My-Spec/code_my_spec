defmodule CodeMySpec.Issues.RemoteClient do
  @moduledoc """
  HTTP client for the remote Issues API.
  """

  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Users.Scope

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

  def list_accepted_issues(client) do
    Req.get(client, url: "/api/issues", params: [status: "accepted"])
  end

  def update_issue(client, issue_id, attrs) do
    Req.put(client, url: "/api/issues/#{issue_id}", json: %{issue: attrs})
  end

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
