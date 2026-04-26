defmodule CodeMySpec.AcceptanceCriteria.RemoteClient do
  @moduledoc """
  HTTP client for the remote AcceptanceCriteria API.

  Implements the same public interface as `AcceptanceCriteriaRepository`
  so the `AcceptanceCriteria` context can swap it in via the
  `:acceptance_criteria_implementation` config key. Used in CLI envs
  (`:dev_cli`, `:prod_cli`) where the local SQLite cache is not the
  canonical store — the server is.

  ## Write-through

  Mutations (`create_criterion`, `update_criterion`, `delete_criterion`,
  `mark_verified`, `mark_unverified`) hit the server first, then upsert/
  delete the returned record into the local SQLite cache. Local-cache
  failures are **logged**, not silenced — a cache write that fails is a
  bug, not noise. The server result is canonical and is returned even if
  the local cache write fails.

  ## Reads

  Read operations hit the local SQLite cache, which is populated by
  `Stories.RemoteSync.upsert_criteria/2` and the write-through above.
  Listing locally avoids hammering the server during UI rendering.
  """

  require Logger

  alias CodeMySpec.AcceptanceCriteria.AcceptanceCriteriaRepository
  alias CodeMySpec.AcceptanceCriteria.Criterion
  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.Story
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
  # Reads — delegated to local cache
  # ---------------------------------------------------------------------------

  defdelegate list_story_criteria(scope, story_id), to: AcceptanceCriteriaRepository
  defdelegate get_criterion(scope, id), to: AcceptanceCriteriaRepository
  defdelegate get_criterion!(scope, id), to: AcceptanceCriteriaRepository

  # ---------------------------------------------------------------------------
  # Writes — server first, then local upsert
  # ---------------------------------------------------------------------------

  def create_criterion(%Scope{} = scope, %Story{} = story, attrs, opts \\ []) do
    client = new(scope, opts)

    payload =
      attrs
      |> stringify_attrs()
      |> Map.put("story_id", story.id)

    case Req.post(client, url: "/api/criteria", json: %{criterion: payload}) do
      {:ok, %{status: 201, body: body}} ->
        criterion = deserialize_criterion(body["data"])
        upsert_criterion_locally(criterion)
        {:ok, criterion}

      {:ok, %{status: 401}} ->
        {:error, :missing_active_scope}

      {:ok, %{status: 404, body: %{"error" => "story_not_found"}}} ->
        {:error, :story_not_found}

      {:ok, %{status: 422, body: %{"error" => "cross_project"}}} ->
        {:error, :cross_project}

      {:ok, %{status: 422, body: body}} ->
        {:error, errors_to_changeset(body, %Criterion{})}
    end
  end

  def update_criterion(%Scope{} = scope, %Criterion{} = criterion, attrs, opts \\ []) do
    client = new(scope, opts)

    case Req.put(client,
           url: "/api/criteria/#{criterion.id}",
           json: %{criterion: stringify_attrs(attrs)}
         ) do
      {:ok, %{status: 200, body: body}} ->
        updated = deserialize_criterion(body["data"])
        upsert_criterion_locally(updated)
        {:ok, updated}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: 422, body: %{"error" => "cross_project"}}} ->
        {:error, :cross_project}

      {:ok, %{status: 422, body: body}} ->
        {:error, errors_to_changeset(body, criterion)}
    end
  end

  def delete_criterion(%Scope{} = scope, %Criterion{} = criterion, opts \\ []) do
    client = new(scope, opts)

    case Req.delete(client, url: "/api/criteria/#{criterion.id}") do
      {:ok, %{status: 200, body: body}} ->
        deleted = deserialize_criterion(body["data"])
        delete_criterion_locally(criterion.id)
        {:ok, deleted}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: 422, body: body}} ->
        {:error, body["error"] |> to_existing_atom_or_default(:unprocessable_entity)}
    end
  end

  def mark_verified(%Scope{} = scope, %Criterion{} = criterion, opts \\ []) do
    update_criterion(
      scope,
      criterion,
      %{verified: true, verified_at: DateTime.utc_now()},
      opts
    )
  end

  def mark_unverified(%Scope{} = scope, %Criterion{} = criterion, opts \\ []) do
    update_criterion(scope, criterion, %{verified: false, verified_at: nil}, opts)
  end

  # ---------------------------------------------------------------------------
  # Deserialization
  # ---------------------------------------------------------------------------

  def deserialize_criterion(data) do
    %Criterion{
      id: data["id"],
      description: data["description"],
      body: data["body"],
      kind: deserialize_kind(data["kind"]),
      verified: data["verified"] || false,
      verified_at: parse_datetime(data["verified_at"]),
      story_id: data["story_id"],
      project_id: data["project_id"],
      rule_id: data["rule_id"],
      inserted_at: parse_datetime(data["inserted_at"]),
      updated_at: parse_datetime(data["updated_at"])
    }
  end

  defp deserialize_kind(nil), do: nil
  defp deserialize_kind(kind) when is_atom(kind), do: kind

  defp deserialize_kind(kind) when is_binary(kind) do
    String.to_existing_atom(kind)
  rescue
    ArgumentError -> nil
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

  defp to_existing_atom_or_default(nil, default), do: default

  defp to_existing_atom_or_default(str, default) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> default
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(datetime_string) when is_binary(datetime_string) do
    case DateTime.from_iso8601(datetime_string) do
      {:ok, datetime, _offset} -> datetime
      {:error, _} -> nil
    end
  end

  defp parse_datetime(%DateTime{} = dt), do: dt

  # ---------------------------------------------------------------------------
  # Write-through to local SQLite cache
  # ---------------------------------------------------------------------------

  defp upsert_criterion_locally(%Criterion{} = criterion) do
    attrs = %{
      description: criterion.description,
      body: criterion.body,
      kind: criterion.kind,
      verified: criterion.verified,
      verified_at: criterion.verified_at,
      story_id: criterion.story_id,
      project_id: criterion.project_id,
      rule_id: criterion.rule_id
    }

    %Criterion{id: criterion.id}
    |> Criterion.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: :id
    )
    |> case do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "[AcceptanceCriteria.RemoteClient] Local upsert failed for criterion #{criterion.id}: #{inspect(changeset.errors)}"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning(
        "[AcceptanceCriteria.RemoteClient] Local upsert raised for criterion #{criterion.id}: #{Exception.message(e)}"
      )

      :ok
  end

  defp delete_criterion_locally(id) do
    case Repo.get(Criterion, id) do
      nil ->
        :ok

      criterion ->
        case Repo.delete(criterion) do
          {:ok, _} ->
            :ok

          {:error, changeset} ->
            Logger.warning(
              "[AcceptanceCriteria.RemoteClient] Local delete failed for criterion #{id}: #{inspect(changeset.errors)}"
            )

            :ok
        end
    end
  rescue
    e ->
      Logger.warning(
        "[AcceptanceCriteria.RemoteClient] Local delete raised for criterion #{id}: #{Exception.message(e)}"
      )

      :ok
  end
end
