defmodule CodeMySpec.Stories.RemoteClient do
  @moduledoc """
  HTTP client for the remote Stories API.

  Implements the same public interface as StoriesRepository so it can be
  swapped in via the `:stories_implementation` config key.

  ## Write-through

  Mutations (`create_story`, `update_story`, `delete_story`,
  `set_story_component`, `clear_story_component`) hit the server first,
  then upsert/delete the returned record into the local SQLite cache.
  Children that depend on a story locally (e.g. `BddRules` write-through)
  rely on the parent row being present, so this keeps freshly-created
  stories addressable without waiting for the boot-time `RemoteSync` pull.
  """

  alias CodeMySpec.AcceptanceCriteria.Criterion
  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @story_error_fields %{
    "title" => :title,
    "description" => :description,
    "status" => :status,
    "priority" => :priority,
    "locked_at" => :locked_at,
    "lock_expires_at" => :lock_expires_at,
    "locked_by" => :locked_by,
    "project_id" => :project_id,
    "component_id" => :component_id,
    "account_id" => :account_id
  }

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
  # List operations
  # ---------------------------------------------------------------------------

  def list_stories(%Scope{} = scope, opts \\ []) do
    client = new(scope, opts)
    {:ok, %{status: 200, body: body}} = Req.get(client, url: "/api/stories")
    Enum.map(body["data"], &deserialize_story/1)
  end

  def list_project_stories(%Scope{} = scope, opts \\ []) do
    client = new(scope, opts)
    {:ok, %{status: 200, body: body}} = Req.get(client, url: "/api/stories-list/project")
    {:ok, Enum.map(body["data"], &deserialize_story/1)}
  end

  def list_project_stories_paginated(%Scope{} = scope, opts \\ []) do
    {client_opts, query_opts} = split_opts(opts)
    client = new(scope, client_opts)

    params =
      query_opts
      |> Keyword.take([:limit, :offset, :search, :tag])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    {:ok, %{status: 200, body: body}} =
      Req.get(client, url: "/api/stories-list/paginated", params: params)

    stories = Enum.map(body["data"], &deserialize_story/1)
    total = body["total"]
    {stories, total}
  end

  def list_story_titles(%Scope{} = scope, opts \\ []) do
    {client_opts, query_opts} = split_opts(opts)
    client = new(scope, client_opts)

    params =
      query_opts
      |> Keyword.take([:search])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    {:ok, %{status: 200, body: body}} =
      Req.get(client, url: "/api/stories-list/titles", params: params)

    # Match StoriesRepository.list_story_titles/2 contract: atom-keyed
    # maps. The JSON API hands back string keys, so we map them here so
    # callers (like StoriesMapper) can pattern-match the same shape
    # against either impl.
    Enum.map(body["data"], fn t ->
      %{
        id: t["id"],
        title: t["title"],
        component_id: t["component_id"]
      }
    end)
  end

  def list_project_stories_by_priority(%Scope{} = scope, opts \\ []) do
    client = new(scope, opts)

    {:ok, %{status: 200, body: body}} =
      Req.get(client, url: "/api/stories-list/by-priority")

    Enum.map(body["data"], &deserialize_story/1)
  end

  def list_unsatisfied_stories(%Scope{} = scope, opts \\ []) do
    client = new(scope, opts)

    {:ok, %{status: 200, body: body}} =
      Req.get(client, url: "/api/stories-list/unsatisfied")

    Enum.map(body["data"], &deserialize_story/1)
  end

  def list_component_stories(%Scope{} = scope, component_id, opts \\ []) do
    client = new(scope, opts)

    {:ok, %{status: 200, body: body}} =
      Req.get(client, url: "/api/stories-list/component/#{component_id}")

    Enum.map(body["data"], &deserialize_story/1)
  end

  # ---------------------------------------------------------------------------
  # Single-record operations
  # ---------------------------------------------------------------------------

  def get_story(%Scope{} = scope, id, opts \\ []) do
    client = new(scope, opts)

    case Req.get(client, url: "/api/stories/#{id}") do
      {:ok, %{status: 200, body: body}} -> deserialize_story(body["data"])
      {:ok, %{status: 404}} -> nil
    end
  end

  def get_story!(%Scope{} = scope, id, opts \\ []) do
    case get_story(scope, id, opts) do
      nil -> raise Ecto.NoResultsError, queryable: Story
      story -> story
    end
  end

  # ---------------------------------------------------------------------------
  # Mutation operations
  # ---------------------------------------------------------------------------

  def create_story(%Scope{} = scope, attrs, opts \\ []) do
    client = new(scope, opts)

    case Req.post(client, url: "/api/stories", json: %{story: stringify_attrs(attrs)}) do
      {:ok, %{status: 201, body: body}} ->
        story = deserialize_story(body["data"])

        with {:ok, _} <- upsert_story_locally(story) do
          {:ok, story}
        end

      {:ok, %{status: 422, body: body}} ->
        {:error, errors_to_changeset(body, %Story{})}
    end
  end

  def update_story(%Scope{} = scope, %Story{} = story, attrs, opts \\ []) do
    client = new(scope, opts)

    case Req.put(client, url: "/api/stories/#{story.id}", json: %{story: stringify_attrs(attrs)}) do
      {:ok, %{status: 200, body: body}} ->
        updated = deserialize_story(body["data"])

        with {:ok, _} <- upsert_story_locally(updated) do
          {:ok, updated}
        end

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: 422, body: body}} ->
        {:error, errors_to_changeset(body, story)}
    end
  end

  def delete_story(%Scope{} = scope, %Story{} = story, opts \\ []) do
    client = new(scope, opts)

    case Req.delete(client, url: "/api/stories/#{story.id}") do
      {:ok, %{status: 200, body: body}} ->
        deleted = deserialize_story(body["data"])

        with {:ok, _} <- delete_story_locally(story.id) do
          {:ok, deleted}
        end

      {:ok, %{status: 404}} ->
        {:error, :not_found}
    end
  end

  def set_story_component(%Scope{} = scope, %Story{} = story, component_id, opts \\ []) do
    client = new(scope, opts)

    case Req.post(client,
           url: "/api/stories/#{story.id}/set-component",
           json: %{component_id: component_id}
         ) do
      {:ok, %{status: 200, body: body}} ->
        updated = deserialize_story(body["data"])

        with {:ok, _} <- upsert_story_locally(updated) do
          {:ok, updated}
        end

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: 422, body: body}} ->
        {:error, errors_to_changeset(body, story)}
    end
  end

  def clear_story_component(%Scope{} = scope, %Story{} = story, opts \\ []) do
    client = new(scope, opts)

    case Req.post(client, url: "/api/stories/#{story.id}/clear-component", json: %{}) do
      {:ok, %{status: 200, body: body}} ->
        updated = deserialize_story(body["data"])

        with {:ok, _} <- upsert_story_locally(updated) do
          {:ok, updated}
        end

      {:ok, %{status: 404}} ->
        {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Deserialization
  # ---------------------------------------------------------------------------

  def deserialize_story(data) do
    %Story{
      id: data["id"],
      title: data["title"],
      description: data["description"],
      acceptance_criteria: data["acceptance_criteria"] || [],
      criteria: parse_criteria(data["criteria"]),
      status: parse_enum(data["status"]),
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

  defp split_opts(opts) do
    client_keys = [:plug, :token]
    client_opts = Keyword.take(opts, client_keys)
    query_opts = Keyword.drop(opts, client_keys)
    {client_opts, query_opts}
  end

  defp stringify_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp errors_to_changeset(%{"errors" => errors}, %Story{} = story) do
    errors
    |> Enum.reduce(Ecto.Changeset.change(story), fn {field, messages}, changeset ->
      field_atom = Map.get(@story_error_fields, field, :base)

      Enum.reduce(List.wrap(messages), changeset, fn msg, cs ->
        Ecto.Changeset.add_error(cs, field_atom, msg)
      end)
    end)
    |> Map.put(:valid?, false)
  end

  defp errors_to_changeset(_body, %Story{} = story) do
    story
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(:base, "unknown error")
    |> Map.put(:valid?, false)
  end

  # Explicit allowlist — decoupled from Ecto.Enum module-load timing so
  # BootSync's async Task can deserialize status strings even if the
  # Story schema module hasn't been hot yet in this session.
  @story_statuses %{
    "in_progress" => :in_progress,
    "completed" => :completed,
    "dirty" => :dirty
  }

  defp parse_enum(nil), do: nil

  defp parse_enum(val) when is_binary(val) do
    case Map.fetch(@story_statuses, val) do
      {:ok, atom} -> atom
      :error -> nil
    end
  end

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

  # ---------------------------------------------------------------------------
  # Write-through to local SQLite cache
  # ---------------------------------------------------------------------------

  defp upsert_story_locally(%Story{} = story) do
    attrs = %{
      title: story.title,
      description: story.description,
      status: story.status,
      priority: story.priority,
      locked_at: story.locked_at,
      lock_expires_at: story.lock_expires_at,
      locked_by: story.locked_by,
      project_id: story.project_id,
      component_id: story.component_id
    }

    # `:first_version_id` and `:current_version_id` are managed by PaperTrail
    # and are NOT NULL FKs in test/web envs (CLI envs make them nullable).
    # On INSERT Postgres validates NOT NULL on the candidate row *before*
    # ON CONFLICT fires, so we must seed the changeset with the existing
    # row's version ids when re-syncing — otherwise the conflict update never
    # gets a chance to run. Excluding them from `:replace_all_except` then
    # preserves whatever was already there.
    version_overrides =
      case Repo.get(Story, story.id) do
        nil -> %{}
        existing -> %{
          first_version_id: existing.first_version_id,
          current_version_id: existing.current_version_id
        }
      end

    with {:ok, persisted} <-
           %Story{id: story.id}
           |> Story.changeset(attrs)
           |> Ecto.Changeset.put_change(:account_id, story.account_id)
           |> Ecto.Changeset.change(version_overrides)
           |> Repo.insert(
             on_conflict:
               {:replace_all_except,
                [:id, :inserted_at, :first_version_id, :current_version_id]},
             conflict_target: :id
           ),
         :ok <- upsert_criteria_locally(story.criteria || [], story.project_id) do
      {:ok, persisted}
    end
  end

  defp upsert_criteria_locally([], _project_id), do: :ok

  defp upsert_criteria_locally(criteria, project_id) do
    Enum.reduce_while(criteria, :ok, fn %Criterion{} = criterion, _acc ->
      attrs = %{
        description: criterion.description,
        verified: criterion.verified,
        verified_at: criterion.verified_at,
        story_id: criterion.story_id,
        project_id: criterion.project_id || project_id
      }

      case %Criterion{id: criterion.id}
           |> Criterion.changeset(attrs)
           |> Repo.insert(
             on_conflict: {:replace_all_except, [:id, :inserted_at]},
             conflict_target: :id
           ) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp delete_story_locally(id) do
    case Repo.get(Story, id) do
      nil -> {:ok, nil}
      story -> Repo.delete(story)
    end
  end
end
