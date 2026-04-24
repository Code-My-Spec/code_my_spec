defmodule CodeMySpec.Personas.RemoteClient do
  @moduledoc """
  HTTP client for the remote Personas API.

  Implements the same public interface as `PersonasRepository` so the context
  can swap it in via the `:personas_implementation` config key. Used in CLI
  envs (`:dev_cli`, `:prod_cli`) where the local process doesn't own the
  canonical personas table — the server does.

  ## Write-through

  Mutations (`create_persona`, `update_persona`, `link_persona_to_story`,
  `unlink_persona_from_story`) hit the server first, then upsert the returned
  record into the local SQLite cache. This keeps `Personas.create_persona/2`
  transparent — whichever impl is configured, callers get a persona back AND
  the local DB reflects it. `PersonasChecker.complete?/2` reads the local DB,
  so this is what makes the checker see CLI-initiated writes without waiting
  for a full `RemoteSync` pull.

  A periodic `RemoteSync.sync/2` still reconciles server-side edits (web UI,
  other CLIs) into the local cache.
  """

  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.Personas.Persona
  alias CodeMySpec.Personas.PersonaStory
  alias CodeMySpec.Repo
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
  # List operations
  # ---------------------------------------------------------------------------

  def list_personas(%Scope{} = scope, opts \\ []) do
    client = new(scope, opts)
    {:ok, %{status: 200, body: body}} = Req.get(client, url: "/api/personas")
    Enum.map(body["data"], &deserialize_persona/1)
  end

  def list_personas_for_story(%Scope{} = scope, story_id, opts \\ []) do
    client = new(scope, opts)

    {:ok, %{status: 200, body: body}} =
      Req.get(client, url: "/api/personas-list/story/#{story_id}")

    Enum.map(body["data"], &deserialize_persona/1)
  end

  def list_personas_for_project(%Scope{} = scope, project_id, opts \\ []) do
    client = new(scope, opts)

    {:ok, %{status: 200, body: body}} =
      Req.get(client, url: "/api/personas-list/project/#{project_id}")

    Enum.map(body["data"], &deserialize_persona/1)
  end

  def list_project_persona_story_links(%Scope{} = scope, project_id, opts \\ []) do
    client = new(scope, opts)

    {:ok, %{status: 200, body: body}} =
      Req.get(client, url: "/api/personas-list/project/#{project_id}/links")

    Enum.map(body["data"], fn %{"persona_id" => pid, "story_id" => sid} -> {pid, sid} end)
  end

  # ---------------------------------------------------------------------------
  # Single-record operations
  # ---------------------------------------------------------------------------

  def get_persona(%Scope{} = scope, id, opts \\ []) do
    client = new(scope, opts)

    case Req.get(client, url: "/api/personas/#{id}") do
      {:ok, %{status: 200, body: body}} -> deserialize_persona(body["data"])
      {:ok, %{status: 404}} -> nil
    end
  end

  def get_persona_by_slug(%Scope{} = scope, slug, opts \\ []) do
    client = new(scope, opts)

    case Req.get(client, url: "/api/personas-by-slug/#{slug}") do
      {:ok, %{status: 200, body: body}} -> deserialize_persona(body["data"])
      {:ok, %{status: 404}} -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Mutation operations
  # ---------------------------------------------------------------------------

  def create_persona(%Scope{} = scope, attrs, opts \\ []) do
    client = new(scope, opts)

    case Req.post(client, url: "/api/personas", json: %{persona: stringify_attrs(attrs)}) do
      {:ok, %{status: 201, body: body}} ->
        persona = deserialize_persona(body["data"])
        upsert_persona_locally(persona)
        {:ok, persona}

      {:ok, %{status: 401}} ->
        {:error, :missing_active_account}

      {:ok, %{status: 422, body: body}} ->
        {:error, errors_to_changeset(body, %Persona{})}
    end
  end

  def update_persona(%Scope{} = scope, %Persona{} = persona, attrs, opts \\ []) do
    client = new(scope, opts)

    case Req.put(client,
           url: "/api/personas/#{persona.id}",
           json: %{persona: stringify_attrs(attrs)}
         ) do
      {:ok, %{status: 200, body: body}} ->
        updated = deserialize_persona(body["data"])
        upsert_persona_locally(updated)
        {:ok, updated}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: 422, body: body}} ->
        {:error, errors_to_changeset(body, persona)}
    end
  end

  def link_persona_to_story(%Scope{} = scope, persona_id, story_id, opts \\ []) do
    client = new(scope, opts)

    case Req.post(client,
           url: "/api/personas/#{persona_id}/link-story",
           json: %{story_id: story_id}
         ) do
      {:ok, %{status: 201, body: body}} ->
        link = deserialize_persona_story(body["data"])
        upsert_link_locally(link)
        {:ok, link}

      {:ok, %{status: 422, body: %{"error" => "cross_account"}}} ->
        {:error, :cross_account}

      {:ok, %{status: 422, body: body}} ->
        {:error, errors_to_changeset(body, %PersonaStory{})}
    end
  end

  def unlink_persona_from_story(%Scope{} = scope, persona_id, story_id, opts \\ []) do
    client = new(scope, opts)

    case Req.post(client,
           url: "/api/personas/#{persona_id}/unlink-story",
           json: %{story_id: story_id}
         ) do
      {:ok, %{status: 200}} ->
        delete_link_locally(persona_id, story_id)
        {:ok, :unlinked}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: 422}} ->
        {:error, :cross_account}
    end
  end

  # ---------------------------------------------------------------------------
  # Deserialization
  # ---------------------------------------------------------------------------

  def deserialize_persona(data) do
    %Persona{
      id: data["id"],
      slug: data["slug"],
      name: data["name"],
      headline: data["headline"],
      persona_type: parse_persona_type(data["persona_type"]),
      account_id: data["account_id"],
      inserted_at: parse_datetime(data["inserted_at"]),
      updated_at: parse_datetime(data["updated_at"])
    }
  end

  def deserialize_persona_story(data) do
    %PersonaStory{
      id: data["id"],
      persona_id: data["persona_id"],
      story_id: data["story_id"],
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

  defp errors_to_changeset(%{"errors" => errors}, %_mod{} = struct) do
    errors
    |> Enum.reduce(Ecto.Changeset.change(struct), fn {field, messages}, changeset ->
      field_atom = String.to_existing_atom(field)

      Enum.reduce(List.wrap(messages), changeset, fn msg, cs ->
        Ecto.Changeset.add_error(cs, field_atom, msg)
      end)
    end)
    |> Map.put(:valid?, false)
  end

  defp errors_to_changeset(_body, %_mod{} = struct) do
    struct
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(:base, "unknown error")
    |> Map.put(:valid?, false)
  end

  @persona_types %{
    "proto" => :proto,
    "qualitative" => :qualitative,
    "statistical" => :statistical
  }

  defp parse_persona_type(nil), do: :proto

  defp parse_persona_type(val) when is_binary(val) do
    Map.get(@persona_types, val, :proto)
  end

  defp parse_persona_type(val) when is_atom(val), do: val

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

  defp upsert_persona_locally(%Persona{} = persona) do
    attrs = %{
      slug: persona.slug,
      name: persona.name,
      headline: persona.headline,
      persona_type: persona.persona_type,
      account_id: persona.account_id
    }

    %Persona{id: persona.id}
    |> Persona.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: :id
    )
  end

  defp upsert_link_locally(%PersonaStory{} = link) do
    %PersonaStory{}
    |> PersonaStory.changeset(%{persona_id: link.persona_id, story_id: link.story_id})
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:persona_id, :story_id])
  end

  defp delete_link_locally(persona_id, story_id) do
    import Ecto.Query

    from(ps in PersonaStory,
      where: ps.persona_id == ^persona_id and ps.story_id == ^story_id
    )
    |> Repo.delete_all()
  end
end
