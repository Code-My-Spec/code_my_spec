defmodule CodeMySpecSpex.Story1013.Criterion2359Spex do
  @moduledoc """
  Story 1013 — A working copy comes onto the harness fully configured.
  Criterion 2359 — A missing database is reported, not created.

  Rule: Onboarding never creates, migrates or drops a database.

  The failure path for the rule, and the one where the temptation is real. A
  missing database is the ordinary state of a fresh working copy — `TestDatabase`
  stopped creating them on 2026-08-13 — so onboarding meets this case every single
  time it runs on a new checkout. That is exactly when "it would be so much
  friendlier to just create it" gets written.

  It is also the case where creating one is most dangerous. The removed code
  created and migrated by shelling out to `mix`, and the environment it passed had
  `MIX_ENV` scrubbed, so "create the test database" meant "act on dev".

  So: completing while touching nothing is the assertion, not merely reporting.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Onboarding never creates, migrates or drops a database" do
    scenario "A missing database is reported, not created" do
      given_ "a working copy whose test databases do not exist", context do
        :ok = Environments.register(context.project.id, context.environment)

        :ok =
          Environments.write_file(
            context.environment,
            ".cms_harness.json",
            Jason.encode!(%{harness_id: "spex-harness-2359"}, pretty: true)
          )

        {:ok, context}
      end

      when_ "the engineer runs the onboarding task", context do
        Mix.Task.reenable("cms.harness.onboard")
        report = Mix.Task.run("cms.harness.onboard", ["--project", context.project.id])

        {:ok, Map.put(context, :report, report)}
      end

      then_ "onboarding completes rather than refusing", context do
        assert %{databases: _} = context.report,
               "onboarding did not complete on a working copy whose databases are " <>
                 "absent. That is the normal state of every fresh checkout, so " <>
                 "refusing there makes the command unusable exactly when it is needed. " <>
                 "Got: #{inspect(context.report)}"

        {:ok, context}
      end

      then_ "it names what is missing and still creates nothing", context do
        assert %{databases: databases, issued_ddl: false} = context.report

        assert Enum.all?(databases, &(&1.name != "" and &1.create != "")),
               "a missing database was reported without the command that would " <>
                 "create it, which leaves the agent knowing it is blocked and not " <>
                 "knowing what to run. Got: #{inspect(databases)}"

        {:ok, context}
      end
    end
  end
end
