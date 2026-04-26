defmodule CodeMySpec.BddRules.RemoteClient do
  @moduledoc """
  HTTP client for the remote BddRules API.

  Implements the same public interface as `BddRulesRepository` so the
  `BddRules` context can swap it in via the `:bdd_rules_implementation`
  config key. Used in CLI envs (`:dev_cli`, `:prod_cli`) where the local
  process doesn't own the canonical bdd_rules table — the server does.

  ## Write-through

  Mutations (`create_rule`, `update_rule`, `delete_rule`) hit the server
  first, then upsert/delete the returned record into the local SQLite
  cache. This keeps `BddRules.create_rule/3` transparent — whichever impl
  is configured, callers get a rule back AND the local DB reflects it.
  `BddRulesChecker.complete?/2` reads the local DB, so this is what
  makes the readiness checker see CLI-initiated writes without waiting
  for a sync pull.
  """

  require Logger

  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.BddRules.BddRulesRepository
  alias CodeMySpec.BddRules.Rule
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
  # Read operations
  # ---------------------------------------------------------------------------

  # Reads from the local SQLite cache. CLI-originated writes land via the
  # write-through in `create_rule/3`. The readiness checker hits this hot
  # per story per requirement-graph rebuild — keep it local. Note: rules
  # created on the server (web UI) require `BddRules.RemoteSync` to land
  # locally; that sync is not yet wired.
  def list_rules_for_story(%Scope{} = scope, story_id, _opts \\ []) do
    BddRulesRepository.list_rules_for_story(scope, story_id)
  end

  def get_rule(%Scope{} = scope, id, opts \\ []) do
    client = new(scope, opts)

    case Req.get(client, url: "/api/bdd-rules/#{id}") do
      {:ok, %{status: 200, body: body}} -> deserialize_rule(body["data"])
      {:ok, %{status: 404}} -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Mutation operations
  # ---------------------------------------------------------------------------

  def create_rule(%Scope{} = scope, story_id, attrs, opts \\ []) do
    client = new(scope, opts)
    payload = attrs |> stringify_attrs() |> Map.put("story_id", coerce_story_id(story_id))

    case Req.post(client, url: "/api/bdd-rules", json: %{rule: payload}) do
      {:ok, %{status: 201, body: body}} ->
        rule = deserialize_rule(body["data"])
        upsert_rule_locally(rule)
        {:ok, rule}

      {:ok, %{status: 401}} ->
        {:error, :missing_active_scope}

      {:ok, %{status: 404, body: %{"error" => "story_not_found"}}} ->
        {:error, :story_not_found}

      {:ok, %{status: 422, body: %{"error" => "persona_linkage_required"}}} ->
        {:error, :persona_linkage_required}

      {:ok, %{status: 422, body: %{"error" => "cross_account"}}} ->
        {:error, :cross_account}

      {:ok, %{status: 422, body: body}} ->
        {:error, errors_to_changeset(body, %Rule{})}
    end
  end

  def update_rule(%Scope{} = scope, %Rule{} = rule, attrs, opts \\ []) do
    client = new(scope, opts)

    case Req.put(client,
           url: "/api/bdd-rules/#{rule.id}",
           json: %{rule: stringify_attrs(attrs)}
         ) do
      {:ok, %{status: 200, body: body}} ->
        updated = deserialize_rule(body["data"])
        upsert_rule_locally(updated)
        {:ok, updated}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: 422, body: %{"error" => "cross_account"}}} ->
        {:error, :cross_account}

      {:ok, %{status: 422, body: body}} ->
        {:error, errors_to_changeset(body, rule)}
    end
  end

  def delete_rule(%Scope{} = scope, %Rule{} = rule, opts \\ []) do
    client = new(scope, opts)

    case Req.delete(client, url: "/api/bdd-rules/#{rule.id}") do
      {:ok, %{status: 200, body: body}} ->
        deleted = deserialize_rule(body["data"])
        delete_rule_locally(rule.id)
        {:ok, deleted}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: 422, body: body}} ->
        {:error, body["error"] |> to_existing_atom_or_default(:unprocessable_entity)}
    end
  end

  # ---------------------------------------------------------------------------
  # Deserialization
  # ---------------------------------------------------------------------------

  def deserialize_rule(data) do
    %Rule{
      id: data["id"],
      account_id: data["account_id"],
      project_id: data["project_id"],
      story_id: data["story_id"],
      statement: data["statement"],
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

  defp coerce_story_id(id) when is_integer(id), do: id
  defp coerce_story_id(id) when is_binary(id), do: String.to_integer(id)

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

  # ---------------------------------------------------------------------------
  # Write-through to local SQLite cache
  # ---------------------------------------------------------------------------

  defp upsert_rule_locally(%Rule{} = rule) do
    attrs = %{
      account_id: rule.account_id,
      project_id: rule.project_id,
      story_id: rule.story_id,
      statement: rule.statement
    }

    %Rule{id: rule.id}
    |> Rule.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: :id
    )
    |> case do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "[BddRules.RemoteClient] Local upsert failed for rule #{rule.id}: #{inspect(changeset.errors)}"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning(
        "[BddRules.RemoteClient] Local upsert raised for rule #{rule.id}: #{Exception.message(e)}"
      )

      :ok
  end

  defp delete_rule_locally(id) do
    case Repo.get(Rule, id) do
      nil ->
        :ok

      rule ->
        case Repo.delete(rule) do
          {:ok, _} ->
            :ok

          {:error, changeset} ->
            Logger.warning(
              "[BddRules.RemoteClient] Local delete failed for rule #{id}: #{inspect(changeset.errors)}"
            )

            :ok
        end
    end
  rescue
    e ->
      Logger.warning(
        "[BddRules.RemoteClient] Local delete raised for rule #{id}: #{Exception.message(e)}"
      )

      :ok
  end
end
