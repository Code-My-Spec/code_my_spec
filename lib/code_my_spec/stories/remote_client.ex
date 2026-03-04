defmodule CodeMySpec.Stories.RemoteClient do
  @moduledoc """
  HTTP client for the remote Stories API.
  """

  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.Stories.Story
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

  def list_project_stories(client) do
    Req.get(client, url: "/api/stories-list/project")
  end

  def set_story_component(client, story_id, component_id) do
    Req.post(client, url: "/api/stories/#{story_id}/set-component", json: %{component_id: component_id})
  end

  # Deserialization — public so callers can convert response bodies to structs

  def deserialize_story(data) do
    %Story{
      id: data["id"],
      title: data["title"],
      description: data["description"],
      acceptance_criteria: data["acceptance_criteria"],
      criteria: parse_criteria(data["criteria"]),
      status: parse_status(data["status"]),
      priority: data["priority"],
      locked_at: parse_datetime(data["locked_at"]),
      lock_expires_at: parse_datetime(data["lock_expires_at"]),
      locked_by: data["locked_by"],
      project_id: data["project_id"],
      component_id: data["component_id"],
      account_id: data["account_id"],
      tags: parse_tags(data["tags"]),
      inserted_at: parse_datetime(data["inserted_at"]),
      updated_at: parse_datetime(data["updated_at"])
    }
  end

  # Private

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

  defp parse_status(nil), do: nil
  defp parse_status(status) when is_binary(status), do: String.to_existing_atom(status)

  defp parse_tags(nil), do: []

  defp parse_tags(tags) when is_list(tags) do
    alias CodeMySpec.Tags.Tag

    Enum.map(tags, fn tag_data ->
      %Tag{
        id: tag_data["id"],
        name: tag_data["name"]
      }
    end)
  end

  defp parse_criteria(nil), do: []

  defp parse_criteria(criteria) when is_list(criteria) do
    alias CodeMySpec.AcceptanceCriteria.Criterion

    Enum.map(criteria, fn criterion_data ->
      %Criterion{
        id: criterion_data["id"],
        description: criterion_data["description"],
        verified: criterion_data["verified"],
        verified_at: parse_datetime(criterion_data["verified_at"]),
        story_id: criterion_data["story_id"],
        project_id: criterion_data["project_id"],
        inserted_at: parse_datetime(criterion_data["inserted_at"]),
        updated_at: parse_datetime(criterion_data["updated_at"])
      }
    end)
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(datetime_string) when is_binary(datetime_string) do
    case DateTime.from_iso8601(datetime_string) do
      {:ok, datetime, _offset} -> datetime
      {:error, _} -> nil
    end
  end
end
