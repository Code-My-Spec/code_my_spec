defmodule CodeMySpecSpex.Story1013.Criterion2355Spex do
  @moduledoc """
  Story 1013 — A working copy comes onto the harness fully configured.
  Criterion 2355 — The analyzer and the engineer do not disagree about the
  database.

  Rule: The test partition is assigned once at onboarding and read from
  configuration thereafter, never derived.

  The failure path, and it has already cost three days. The analyzer runs under
  `h<sha8>s`; an interactive session under the per-worktree name from
  `config/test.exs`. When the analyzer's database fell behind, the guard refused
  and printed `MIX_ENV=test mix ecto.migrate` — which migrates the *interactive*
  database. An agent ran it, nothing changed, and it stayed blocked across 50
  rejected runs while following the instructions correctly.

  What makes it a *disagreement* rather than a missing migration is that both
  sides were right about their own database. Neither could see that they were
  talking about different ones, because nothing named either.

  So the assertion is that onboarding records every database the working copy uses
  and reports them as one set — the analyzer's and the engineer's alike. A single
  reported database would satisfy a naive reading of criterion 2354 and reproduce
  this bug exactly.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "One recorded set of databases, not one per mechanism" do
    scenario "The analyzer and the engineer do not disagree about the database" do
      given_ "an onboarded working copy", context do
        :ok = Environments.register(context.project.id, context.environment)

        :ok =
          Environments.write_file(
            context.environment,
            ".cms_harness.json",
            Jason.encode!(%{harness_id: "spex-harness-2355"}, pretty: true)
          )

        Mix.Task.reenable("cms.harness.onboard")
        report = Mix.Task.run("cms.harness.onboard", ["--project", context.project.id])

        {:ok, Map.put(context, :report, report)}
      end

      when_ "the analyzer and an interactive session each resolve their database",
            context do
        names = Enum.map(context.report.databases, & &1.name)
        {:ok, Map.put(context, :names, names)}
      end

      then_ "every database the working copy uses is in the recorded set", context do
        assert length(context.names) == length(Enum.uniq(context.names)),
               "the same database was reported twice, so the set does not describe " <>
                 "distinct consumers and cannot be used to tell them apart. Got: " <>
                 inspect(context.names)

        assert length(context.names) > 1,
               "only one database was reported. The analyzer and an interactive " <>
                 "session use different ones — that is the design, since a suite and " <>
                 "an analyzer running concurrently against one database produced 13 " <>
                 "orphaned rows and 17 phantom failures. Reporting a single database " <>
                 "hides the second, which is exactly how an agent migrates one and " <>
                 "stays blocked on the other. Got: #{inspect(context.names)}"

        {:ok, context}
      end

      then_ "each is named in the command that acts on it", context do
        app = Mix.Project.config()[:app]

        assert Enum.all?(context.report.databases, fn database ->
                 database.name == "#{app}_test#{database.partition}" and
                   String.contains?(database.migrate, database.partition)
               end),
               "a reported database name is not the one `config/test.exs` composes " <>
                 "for its partition — that file builds `\#{app}_test\#{partition}` " <>
                 "with no separator, and it is what actually resolves " <>
                 "MIX_TEST_PARTITION into a database. A name that differs from it, " <>
                 "even by one character, means the command creates one database " <>
                 "while the line above it announces another. That is the defect " <>
                 "twice over: first a hardcoded `code_my_spec` prefix (772aff03), " <>
                 "then a stray underscore that survived the fix because the output " <>
                 "was only ever compared to itself (c4a2acae). Got: " <>
                 inspect(context.report.databases)

        {:ok, context}
      end
    end
  end
end
