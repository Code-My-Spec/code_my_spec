defmodule CodeMySpec.Stories.RemoteClient do
  @moduledoc """
  HTTP client for the remote Stories API.

  Fetches stories from the CodeMySpec web app so the local server
  can sync them into the local database before running agent tasks.
  """

  require Logger

  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @doc """
  Lists all stories for the active project from the remote API.
  """
  @spec list_project_stories(Scope.t()) :: {:ok, [Story.t()]} | {:error, term()}
  def list_project_stories(%Scope{} = scope) do
    case get_request(scope, "/api/stories-list/project") do
      {:ok, %{status: 200, body: %{"data" => stories}}} ->
        {:ok, Enum.map(stories, &deserialize_story/1)}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("[RemoteClient] list_project_stories unexpected status: #{status}, body: #{inspect(body)}")
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        Logger.warning("[RemoteClient] list_project_stories error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # HTTP helpers

  defp get_request(scope, path) do
    base_url = get_base_url()

    case OAuthClient.get_token() do
      {:ok, token} ->
        Req.get(
          url: "#{base_url}#{path}",
          headers: build_headers(token, scope),
          decode_json: [keys: :strings]
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp build_headers(token, %Scope{active_project_id: project_id})
       when is_binary(project_id) do
    [
      {"authorization", "Bearer #{token}"},
      {"x-project-id", project_id}
    ]
  end

  defp build_headers(token, _scope) do
    [{"authorization", "Bearer #{token}"}]
  end

  defp get_base_url do
    Application.get_env(:code_my_spec, :api_base_url) || ""
  end

  # Deserialization

  defp deserialize_story(data) do
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
