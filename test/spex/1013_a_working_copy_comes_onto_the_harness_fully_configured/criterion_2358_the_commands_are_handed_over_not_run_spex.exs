defmodule CodeMySpecSpex.Story1013.Criterion2358Spex do
  @moduledoc """
  Story 1013 — A working copy comes onto the harness fully configured.
  Criterion 2358 — The commands are handed over, not run.

  Rule: Onboarding never creates, migrates or drops a database.

  The rule exists because the removed version of this shelled out to `mix` with an
  environment that had `MIX_ENV` scrubbed out of it. It therefore ran against
  **dev** — the database every agent shares — and a sibling truncate emptied it
  three times on 2026-08-13, reporting the rows it destroyed as escaped test data
  while it did so.

  The decision taken was to keep the rule whole rather than carve an explicit
  onboarding exception into it. So onboarding computes what is needed and hands it
  over; the agent runs it.

  Asserted through the environment rather than by watching for DDL, because the
  environment is the only thing a spec can observe and because "it wrote nothing"
  is the honest form of "it ran nothing" here — a task with no database
  connection cannot migrate anything.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Onboarding never creates, migrates or drops a database" do
    scenario "The commands are handed over, not run" do
      given_ "a working copy being onboarded", context do
        :ok = Environments.register(context.project.id, context.environment)
        {:ok, context}
      end

      when_ "the engineer runs the onboarding task", context do
        Mix.Task.reenable("cms.onboard_harness")
        report = Mix.Task.run("cms.onboard_harness", ["--project", context.project.id])

        {:ok, Map.put(context, :report, report)}
      end

      then_ "each database it needs is reported with its own commands", context do
        assert %{databases: [_ | _] = databases} = context.report

        assert Enum.all?(databases, fn database ->
                 String.contains?(database.create, database.name) and
                   String.contains?(database.migrate, database.name)
               end),
               "a command was handed over that does not name the database it acts " <>
                 "on. That is precisely the failure of the migration guard, which " <>
                 "printed `MIX_ENV=test mix ecto.migrate` while checking a partition " <>
                 "that command never touches — an agent followed it, migrated the " <>
                 "wrong database, and stayed blocked for three days across 50 " <>
                 "rejected runs. Got: #{inspect(databases)}"

        {:ok, context}
      end

      then_ "it reports having issued no DDL of its own", context do
        assert %{issued_ddl: false} = context.report,
               "onboarding claims to have issued DDL. It runs in whatever environment " <>
                 "invoked it, which on 2026-08-13 resolved to the shared development " <>
                 "database three times. Naming the commands is the job; running them " <>
                 "is the agent's. Got: #{inspect(context.report)}"

        {:ok, context}
      end
    end
  end
end
