defmodule CodeMySpecSpex.Story1013.Criterion2350Spex do
  @moduledoc """
  Story 1013 — A working copy comes onto the harness fully configured.
  Criterion 2350 — A worktree the agent made is configured by one command run
  inside it.

  Rule: One command takes a working copy from checkout to ready.

  The whole story in one scenario. Onboarding is currently not a step — it is a
  set of values every consumer re-derives, and each derivation has failed in
  production. This asserts the opposite shape: one command, run inside a worktree
  the agent already made, after which the copy is configured and whatever it
  cannot do itself is named.

  "Ready" here does not mean the databases exist. Onboarding never issues DDL
  (criterion 2358), so ready means *configured, with the remainder stated* — and
  the second `then_` is what keeps that from quietly becoming "configured, with
  the remainder omitted".
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project

  @settings ".claude/settings.local.json"

  spex "One command takes a working copy from checkout to ready" do
    scenario "A worktree the agent made is configured by one command run inside it" do
      given_ "a worktree with no harness configuration", context do
        :ok = Environments.register(context.project.id, context.environment)

        :ok =
          Environments.write_file(
            context.environment,
            ".cms_harness.json",
            Jason.encode!(%{working_copy_id: "spex-harness-2350"}, pretty: true)
          )

        refute Environments.file_exists?(context.environment, @settings),
               "the premise failed: this working copy is already configured"

        {:ok, context}
      end

      when_ "the engineer runs the onboarding task inside it", context do
        Mix.Task.reenable("cms.harness.onboard")
        report = Mix.Task.run("cms.harness.onboard", ["--project", context.project.id])

        {:ok, Map.put(context, :report, report)}
      end

      then_ "its identity and partition are set", context do
        assert {:ok, settings} = Environments.read_file(context.environment, @settings),
               "onboarding wrote no #{@settings}, so nothing about this working " <>
                 "copy's identity was recorded and every consumer is left to derive it."

        assert settings =~ "CMS_HARNESS_ID",
               "no harness id, so the MCP mount cannot name this working copy and " <>
                 "every tool call goes unaddressed. Got: #{settings}"

        assert settings =~ "MIX_TEST_PARTITION",
               "no test partition, which is the value two independent mechanisms " <>
                 "currently derive and disagree about. Recording it is the whole " <>
                 "point of this story. Got: #{settings}"

        {:ok, context}
      end

      then_ "everything it did not do is named", context do
        assert %{databases: [_ | _] = databases} = context.report,
               "onboarding reported no databases. It is not allowed to create them " <>
                 "(criterion 2358), so naming them is the only way the agent learns " <>
                 "what is left. Reporting none is indistinguishable from a working " <>
                 "copy that needs nothing. Got: #{inspect(context.report)}"

        assert Enum.all?(databases, &match?(%{name: _, create: _, migrate: _}, &1)),
               "a reported database is missing its name or one of its commands, so " <>
                 "the agent is told something is outstanding without being told what " <>
                 "to run. That is the failure this story exists to end: a refusal " <>
                 "whose remedy cannot be acted on. Got: #{inspect(databases)}"

        {:ok, context}
      end
    end
  end
end
