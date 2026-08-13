defmodule CodeMySpecSpex.Story1013.Criterion2360Spex do
  @moduledoc """
  Story 1013 — A working copy comes onto the harness fully configured.
  Criterion 2360 — The output is sufficient to finish the job.

  Rule: An agent can finish onboarding from what the command told it, without
  reading source.

  The criterion this story was written for. Every incident behind story 1013 was
  survivable information delivered somewhere the actor could not act on it: a
  refusal naming a command for the wrong database, a partition computed by a
  digest function no message mentions, a comment describing an invariant that had
  been removed. In each case the answer existed and the agent could not reach it.

  So sufficiency is the assertion. Not that a report exists — that following it,
  and nothing else, finishes the job.

  Deliberately asserts on the commands being runnable as given rather than on
  prose quality. A command an agent can paste is checkable; "clear guidance" is
  not, and a criterion that cannot fail is not a criterion.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Onboarding hands over everything needed to finish" do
    scenario "The output is sufficient to finish the job" do
      given_ "a working copy that has just been onboarded", context do
        :ok = Environments.register(context.project.id, context.environment)

        Mix.Task.reenable("cms.onboard_harness")
        report = Mix.Task.run("cms.onboard_harness", ["--project", context.project.id])

        {:ok, Map.put(context, :report, report)}
      end

      when_ "the agent reads what it was told and nothing else", context do
        %{databases: databases} = context.report
        commands = Enum.flat_map(databases, &[&1.create, &1.migrate])

        {:ok, Map.put(context, :commands, commands)}
      end

      then_ "every remaining step is a command it can run as given", context do
        assert context.commands != [],
               "onboarding handed over no commands at all, so an agent with " <>
                 "outstanding work has nothing to act on and must go read source to " <>
                 "find out what. Got: #{inspect(context.report)}"

        assert Enum.all?(context.commands, &String.contains?(&1, "mix")),
               "a handed-over step is not a runnable command. Prose describing what " <>
                 "ought to happen is what the migration guard already produced, and " <>
                 "an agent followed it to the wrong database. Got: " <>
                 inspect(context.commands)

        {:ok, context}
      end

      then_ "no step requires knowing a value the command did not state", context do
        %{databases: databases} = context.report

        assert Enum.all?(databases, fn database ->
                 String.contains?(database.create, database.name) and
                   String.contains?(database.migrate, database.name)
               end),
               "a command depends on a value the report never named, so running it " <>
                 "means first working out which database is meant — by reading the " <>
                 "digest function, which is the specific thing this story exists to " <>
                 "make unnecessary. Got: #{inspect(databases)}"

        {:ok, context}
      end
    end
  end
end
