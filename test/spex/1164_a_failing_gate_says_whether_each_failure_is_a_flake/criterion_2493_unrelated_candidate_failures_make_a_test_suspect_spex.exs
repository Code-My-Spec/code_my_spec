defmodule CodeMySpecSpex.Story1164.Criterion2493Spex do
  @moduledoc """
  Story 1164: A failing gate reports the evidence for each flaky test.
  Criterion 2493: Failures across unrelated candidates make a test suspect.

  This increment records the classification in the promotion log.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers
  import ExUnit.CaptureLog

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @test_file "test/broken_oaths/diplomacy/war_test.exs"
  @name "test declares war"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Repeated failures in unrelated candidates make a test suspect", criterion: 2493 do
    scenario "the fourth unrelated candidate fails the same test" do
      given_ "three prior candidates failed test A without changing its file or covered code",
             context do
        context = context |> a_promotable_project() |> an_agent_on_the_copy()
        commit_work(context, context.agent_root, "lib/broken_oaths/diplomacy/peace.ex", peace())
        context = Map.put(context, :story, a_promotable_story(context))
        analyzers_are_current(context)

        {context, candidates} =
          Enum.reduce(1..3, {context, []}, fn number, {context, candidates} ->
            key = String.to_atom("unrelated_#{number}")
            context = another_candidate(context, key)
            candidate = Map.fetch!(context, key)

            commit_work(
              context,
              candidate.root,
              "lib/unrelated_#{number}.ex",
              "defmodule Unrelated#{number} do\nend\n"
            )

            run =
              Fixtures.finished_analysis_run_with_findings(candidate.scope,
                source: "exunit",
                commit: head_of(context, candidate.root),
                failures: [failure()],
                problems: []
              )

            {context, [run | candidates]}
          end)

        {:ok, Map.put(context, :candidates, Enum.reverse(candidates))}
      end

      when_ "the candidate's gate fails test A", context do
        promote(context, context.story.number)

        log =
          capture_log([level: :info], fn ->
            the_gate_answers(context, %{"exunit" => [failure()]})
            what_the_agent_was_told(context)
          end)

        {:ok, Map.put(context, :log, log)}
      end

      then_ "one line classifies test A as suspect and cites all three earlier candidates",
            context do
        line = Enum.find(String.split(context.log, "\n"), &String.contains?(&1, @name))
        assert line, context.log
        assert line =~ @test_file
        assert line =~ "suspect"

        for candidate <- context.candidates do
          assert line =~ candidate.working_copy_id
        end

        {:ok, context}
      end
    end
  end

  defp failure do
    %{"file" => @test_file, "line" => 3, "name" => @name, "message" => "war declaration failed"}
  end

  defp peace, do: "defmodule BrokenOaths.Diplomacy.Peace do\n  def keep, do: :ok\nend\n"
end
