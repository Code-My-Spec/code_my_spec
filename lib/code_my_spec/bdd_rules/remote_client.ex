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

  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.BddRules.BddRulesRepository
  alias CodeMySpec.BddRules.Rule
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @error_atoms %{
    "story_not_found" => :story_not_found,
    "persona_linkage_required" => :persona_linkage_required,
    "cross_account" => :cross_account,
    "not_found" => :not_found,
    "missing_active_scope" => :missing_active_scope,
    "unprocessable_entity" => :unprocessable_entity
  }

  @rule_error_fields %{
    "account_id" => :account_id,
    "project_id" => :project_id,
    "story_id" => :story_id,
    "statement" => :statement
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
  # Read operations
  # ---------------------------------------------------------------------------

  # Reads from the local SQLite cache. CLI-originated writes land via the
  # write-through in `create_rule/3`. The readiness checker hits this hot
  # per story per requirement-graph rebuild — keep it local. Server-originated
  # edits (web UI) land via `BddRules.RemoteSync` (boot + `sync_project`).
  def list_rules_for_story(%Scope{} = scope, story_id, _opts \\ []) do
    BddRulesRepository.list_rules_for_story(scope, story_id)
  end

  def list_rules_for_project(%Scope{} = scope, project_id, opts \\ []) do
    client = new(scope, opts)

    {:ok, %{status: 200, body: body}} =
      Req.get(client, url: "/api/bdd-rules-list/project/#{project_id}")

    Enum.map(body["data"], &deserialize_rule/1)
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

        with {:ok, _} <- upsert_rule_locally(rule) do
          {:ok, rule}
        end

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

        with {:ok, _} <- upsert_rule_locally(updated) do
          {:ok, updated}
        end

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

        with {:ok, _} <- delete_rule_locally(rule.id) do
          {:ok, deleted}
        end

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: 422, body: body}} ->
        {:error, parse_error_atom(body["error"])}
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
      field_atom = Map.get(@rule_error_fields, field, :base)

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

  defp parse_error_atom(nil), do: :unprocessable_entity

  defp parse_error_atom(str) when is_binary(str),
    do: Map.get(@error_atoms, str, :unprocessable_entity)

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
  end

  defp delete_rule_locally(id) do
    case Repo.get(Rule, id) do
      nil -> {:ok, nil}
      rule -> Repo.delete(rule)
    end
  end
end
