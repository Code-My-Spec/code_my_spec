defmodule CmsHarness.Migrate do
  @moduledoc """
  `cms migrate --project <cloud-project-id>`: copy a checkout's authored graph
  from the local CLI database to a cloud project.

  The one thing in a harness build that opens a database, and deliberately not
  the harness: it boots the Repo and the CLI migrations (`Migrator`), runs
  once, and halts on the outcome. The harness itself still holds no database.
  """

  alias CodeMySpec.LocalScope
  alias CodeMySpec.Migration

  @doc """
  Whether this boot is `cms migrate`.

  Env-var fallback because a release that is not Burrito-packaged never threads
  argv through, so the subcommand alone cannot reach this.
  """
  @spec command?([String.t()]) :: boolean()
  def command?(argv) do
    "migrate" in Enum.reject(argv, &(&1 in ["--", ""])) or
      System.get_env("CMS_MIGRATE") in ["1", "true"]
  end

  @doc "Boot the database, run the migration, halt on the outcome."
  def start(argv) do
    children = [
      CodeMySpec.Vault,
      CodeMySpec.Repo,
      CodeMySpec.ExecutionContexts.registry_child_spec(),
      CmsHarness.Migrate.Migrator
    ]

    {:ok, pid} =
      Supervisor.start_link(children, strategy: :one_for_one, name: CodeMySpec.Supervisor)

    argv |> run() |> report()

    {:ok, pid}
  end

  defp run(argv) do
    with {:ok, cloud_project_id} <- target(argv),
         working_dir = File.cwd!(),
         {:ok, project} <- CodeMySpec.Projects.resolve_local_project(working_dir),
         {:ok, scope} <- LocalScope.for_local_project(project, working_dir) do
      IO.puts("Migrating #{project.name} to cloud project #{cloud_project_id}…")

      Migration.Client.migrate(
        scope,
        Keyword.reject([cloud_project_id: cloud_project_id, token: token_override()], fn
          {:token, nil} -> true
          _ -> false
        end)
      )
    end
  end

  # `CMS_TOKEN`, an override for this one migration. Without it, `Migration.Client.migrate/2` falls back to
  # `OAuthClient.get_token()` — the token stored locally from whichever
  # server this CLI last logged into, which does not validate against a
  # *different* server (a dev instance has its own signing key and user
  # table; a token minted by one is simply not a token the other issued).
  defp token_override, do: System.get_env("CMS_TOKEN")

  # `--project <id>` names the cloud project to fill. It is deliberately not
  # inferred: the local project's id means nothing on the server, and guessing
  # by name could pour one project's work into another's.
  defp target(argv) do
    case Enum.drop_while(argv, &(&1 != "--project")) do
      ["--project", id | _] when id != "" -> {:ok, id}
      _ -> project_id_from_env()
    end
  end

  # `CMS_CLOUD_PROJECT_ID` first: the cloud mints its own id, so it is only by
  # coincidence that it ever equals `CMS_PROJECT_ID` — which names the *local*
  # project to `resolve_local_project/1`. Falling back to it keeps working for
  # anyone whose ids do happen to match.
  defp project_id_from_env do
    case System.get_env("CMS_CLOUD_PROJECT_ID") || System.get_env("CMS_PROJECT_ID") do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :missing_project}
    end
  end

  defp report({:ok, summary}) do
    IO.puts("\nMigrated:")

    Enum.each(summary, fn
      {kind, values} when is_list(values) -> IO.puts("  #{kind}: #{Enum.join(values, ", ")}")
      {kind, count} -> IO.puts("  #{kind}: #{count}")
    end)

    IO.puts("\nThe local copy is untouched. The two are independent from here.")
    System.halt(0)
  end

  defp report({:error, :missing_project}), do: failed(no_project_message())
  defp report({:error, :cloud_project_id_required}), do: failed(no_project_message())
  defp report({:error, {:refused, _status, reason}}), do: failed(reason)

  defp report({:error, {:unreachable, reason}}),
    do: failed("could not reach the server: #{inspect(reason)}")

  defp report({:error, reason}), do: failed(inspect(reason))

  defp no_project_message,
    do:
      "name the cloud project — either `cms-migrate --project <cloud-project-id>` " <>
        "or set CMS_CLOUD_PROJECT_ID"

  defp failed(message) do
    IO.puts(:stderr, "\ncms migrate: #{message}")
    IO.puts(:stderr, "Nothing was copied. The local copy is untouched.")
    System.halt(1)
  end
end
