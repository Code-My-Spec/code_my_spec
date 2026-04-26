defmodule CodeMySpec.Questions.RemoteClient do
  @moduledoc """
  HTTP client for the remote Questions API.

  Implements the same public interface as `QuestionsRepository` so the
  `Questions` context can swap it in via the `:questions_implementation`
  config key. Used in CLI envs (`:dev_cli`, `:prod_cli`) where the local
  process doesn't own the canonical questions table — the server does.

  ## Write-through

  Mutations (`create_question`, `update_question`, `delete_question`) hit
  the server first, then upsert/delete the returned record into the local
  SQLite cache so the readiness checker (`BddRulesChecker.complete?/2`)
  sees CLI-initiated writes without waiting for a sync pull.
  """

  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.Questions.Question
  alias CodeMySpec.Questions.QuestionsRepository
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
  # write-through in `create_question/3`. The readiness checker hits this
  # hot per story per requirement-graph rebuild — keep it local. Note:
  # questions created on the server (web UI) require `Questions.RemoteSync`
  # to land locally; that sync is not yet wired.
  def list_questions_for_story(%Scope{} = scope, story_id, _opts \\ []) do
    QuestionsRepository.list_questions_for_story(scope, story_id)
  end

  def get_question(%Scope{} = scope, id, opts \\ []) do
    client = new(scope, opts)

    case Req.get(client, url: "/api/questions/#{id}") do
      {:ok, %{status: 200, body: body}} -> deserialize_question(body["data"])
      {:ok, %{status: 404}} -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Mutation operations
  # ---------------------------------------------------------------------------

  def create_question(%Scope{} = scope, story_id, attrs, opts \\ []) do
    client = new(scope, opts)
    payload = attrs |> stringify_attrs() |> Map.put("story_id", coerce_story_id(story_id))

    case Req.post(client, url: "/api/questions", json: %{question: payload}) do
      {:ok, %{status: 201, body: body}} ->
        question = deserialize_question(body["data"])
        upsert_question_locally(question)
        {:ok, question}

      {:ok, %{status: 401}} ->
        {:error, :missing_active_scope}

      {:ok, %{status: 404, body: %{"error" => "story_not_found"}}} ->
        {:error, :story_not_found}

      {:ok, %{status: 422, body: %{"error" => "cross_account"}}} ->
        {:error, :cross_account}

      {:ok, %{status: 422, body: body}} ->
        {:error, errors_to_changeset(body, %Question{})}
    end
  end

  def update_question(%Scope{} = scope, %Question{} = question, attrs, opts \\ []) do
    client = new(scope, opts)

    case Req.put(client,
           url: "/api/questions/#{question.id}",
           json: %{question: stringify_attrs(attrs)}
         ) do
      {:ok, %{status: 200, body: body}} ->
        updated = deserialize_question(body["data"])
        upsert_question_locally(updated)
        {:ok, updated}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: 422, body: %{"error" => "cross_account"}}} ->
        {:error, :cross_account}

      {:ok, %{status: 422, body: body}} ->
        {:error, errors_to_changeset(body, question)}
    end
  end

  def delete_question(%Scope{} = scope, %Question{} = question, opts \\ []) do
    client = new(scope, opts)

    case Req.delete(client, url: "/api/questions/#{question.id}") do
      {:ok, %{status: 200, body: body}} ->
        deleted = deserialize_question(body["data"])
        delete_question_locally(question.id)
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

  def deserialize_question(data) do
    %Question{
      id: data["id"],
      account_id: data["account_id"],
      project_id: data["project_id"],
      story_id: data["story_id"],
      text: data["text"],
      status: parse_status(data["status"]),
      inserted_at: parse_datetime(data["inserted_at"]),
      updated_at: parse_datetime(data["updated_at"])
    }
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @statuses %{
    "open" => :open,
    "resolved" => :resolved,
    "deferred" => :deferred
  }

  defp parse_status(nil), do: :open
  defp parse_status(val) when is_atom(val), do: val
  defp parse_status(val) when is_binary(val), do: Map.get(@statuses, val, :open)

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

  defp upsert_question_locally(%Question{} = question) do
    attrs = %{
      account_id: question.account_id,
      project_id: question.project_id,
      story_id: question.story_id,
      text: question.text,
      status: question.status
    }

    %Question{id: question.id}
    |> Question.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: :id
    )
  end

  defp delete_question_locally(id) do
    case Repo.get(Question, id) do
      nil -> :ok
      question -> Repo.delete(question)
    end
  end
end
