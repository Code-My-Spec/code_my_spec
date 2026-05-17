# Migrate legacy result_complete.md files into the new Qa.QaAttempt table.
#
# Out-of-harness operational script. Run once after the qa_complete
# checker cuts over to DB-driven satisfaction:
#
#   mix run priv/repo/scripts/migrate_qa_attempts_from_files.exs
#
# Idempotent: skips stories that already have a DB attempt. Sets the
# attempt's submitted_at to the file's mtime, agent_id to
# "legacy-file-migration", and scenarios to a single placeholder row
# noting the migration source. The original result_complete.md files
# are left in place (cleanup is manual — they're no longer
# load-bearing once this runs).

defmodule QaMigration do
  @moduledoc false

  import Ecto.Query

  alias CodeMySpec.Qa.QaAttempt
  alias CodeMySpec.Repo

  def run(qa_root) do
    IO.puts("Migrating legacy result_complete.md files from #{qa_root}")

    case File.dir?(qa_root) do
      false ->
        IO.puts("No qa directory at #{qa_root} — nothing to migrate.")
        :ok

      true ->
        do_run(qa_root)
    end
  end

  defp do_run(qa_root) do
    story_dirs = story_dirs(qa_root)
    IO.puts("Found #{length(story_dirs)} story directories.")

    {migrated, skipped, errors} =
      Enum.reduce(story_dirs, {0, 0, []}, fn dir, acc ->
        process_dir(qa_root, dir, acc)
      end)

    report(migrated, skipped, errors)

    case errors do
      [] -> :ok
      _ -> {:error, errors}
    end
  end

  defp story_dirs(qa_root) do
    qa_root
    |> File.ls!()
    |> Enum.filter(fn name -> File.dir?(Path.join(qa_root, name)) end)
    |> Enum.filter(fn name -> Integer.parse(name) != :error end)
    |> Enum.sort()
  end

  defp process_dir(qa_root, dir, {m, s, errs}) do
    story_id = parse_story_id(dir)
    result_path = Path.join([qa_root, dir, "result_complete.md"])

    cond do
      is_nil(story_id) ->
        {m, s, errs}

      not File.exists?(result_path) ->
        {m, s, errs}

      already_has_attempt?(story_id) ->
        IO.puts("[skip] story #{story_id} — DB attempt already present")
        {m, s + 1, errs}

      true ->
        case migrate_one(story_id, result_path) do
          :ok ->
            IO.puts("[ok]   story #{story_id} — migrated #{result_path}")
            {m + 1, s, errs}

          {:error, reason} ->
            IO.puts("[err]  story #{story_id} — #{inspect(reason)}")
            {m, s, [{story_id, reason} | errs]}
        end
    end
  end

  defp parse_story_id(dir) do
    case Integer.parse(dir) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp already_has_attempt?(story_id) do
    Repo.exists?(from a in QaAttempt, where: a.story_id == ^story_id)
  end

  defp migrate_one(story_id, result_path) do
    %File.Stat{mtime: mtime_erl} = File.stat!(result_path)
    submitted_at = NaiveDateTime.from_erl!(mtime_erl) |> DateTime.from_naive!("Etc/UTC")

    attrs = %{
      story_id: story_id,
      status: :pass,
      scenarios: [
        %{
          name: "migrated",
          status: :pass,
          observation: "Seeded from legacy result_complete.md at #{result_path}"
        }
      ],
      issue_ids: [],
      agent_id: "legacy-file-migration",
      task_id: nil,
      parent_attempt_id: nil,
      submitted_at: submitted_at
    }

    %QaAttempt{}
    |> QaAttempt.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, _attempt} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp report(migrated, skipped, errors) do
    IO.puts("\nMigration complete:")
    IO.puts("  migrated: #{migrated}")
    IO.puts("  skipped:  #{skipped}")
    IO.puts("  errors:   #{length(errors)}")

    case errors do
      [] ->
        :ok

      _ ->
        IO.puts("\nFailures:")
        Enum.each(errors, fn {story_id, reason} ->
          IO.puts("  story #{story_id}: #{inspect(reason)}")
        end)
    end
  end
end

qa_root =
  System.get_env("QA_DIR") ||
    Path.join([File.cwd!(), ".code_my_spec", "qa"])

case QaMigration.run(qa_root) do
  :ok -> :ok
  {:error, _} -> System.halt(1)
end
