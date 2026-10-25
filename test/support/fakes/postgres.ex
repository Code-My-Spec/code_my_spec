defmodule CodeMySpecSpex.Fakes.Postgres do
  @moduledoc "In-memory database ownership and CONNECT ACLs for provisioning tests."
  alias CodeMySpec.ExecutionContexts

  @path "/fake-postgres.json"

  def connect(env, role, database) do
    case Map.fetch(state(env), database) do
      {:ok, entry} ->
        if entry["public"] or role in entry["connect"] or role == entry["username"] do
          {"1", 0}
        else
          {"permission denied for database #{database}", 2}
        end

      :error ->
        {"database does not exist", 2}
    end
  end

  def run(env, command) do
    cond do
      String.starts_with?(command, "docker ps") ->
        {"c0ffeec0ffee", 0}

      String.contains?(command, "json_agg") ->
        tenants =
          Enum.map(state(env), fn {database, entry} ->
            %{database: database, username: entry["username"]}
          end)

        {Jason.encode!(Enum.sort_by(tenants, & &1.database)), 0}

      String.contains?(command, "SELECT 1 FROM pg_database") ->
        {"1", 0}

      String.contains?(command, "psql") ->
        apply_sql(env, command)

      true ->
        {"unmodelled Postgres command", 127}
    end
  end

  def seed(env, database, owner) do
    save(
      env,
      Map.put(state(env), database, %{"username" => owner, "public" => true, "connect" => []})
    )
  end

  defp apply_sql(env, command) do
    updated =
      Regex.scan(
        ~r/(REVOKE|GRANT) CONNECT ON DATABASE "([^"]+)" (?:FROM|TO) (PUBLIC|"[^"]+")/,
        command
      )
      |> Enum.reduce(state(env), fn [_, action, database, target], acc ->
        Map.update!(acc, database, fn entry ->
          case {action, target} do
            {"REVOKE", "PUBLIC"} -> Map.put(entry, "public", false)
            {"GRANT", "PUBLIC"} -> Map.put(entry, "public", true)
            {"GRANT", role} -> Map.update!(entry, "connect", &[String.trim(role, "\"") | &1])
          end
        end)
      end)

    :ok = save(env, updated)
    {"", 0}
  end

  defp state(env) do
    case ExecutionContexts.read_file(env, @path) do
      {:ok, json} -> Jason.decode!(json)
      _ -> %{}
    end
  end

  defp save(env, state), do: ExecutionContexts.write_file(env, @path, Jason.encode!(state))
end
