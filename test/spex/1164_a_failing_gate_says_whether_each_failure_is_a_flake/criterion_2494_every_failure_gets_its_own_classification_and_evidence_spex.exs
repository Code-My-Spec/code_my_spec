defmodule CodeMySpecSpex.Story1164.Criterion2494Spex do
  @moduledoc """
  Story 1164: A failing gate reports the evidence for each flaky test.
  Criterion 2494: Every failure gets its own classification and evidence.

  The first increment observes the promotion log, leaving ejection text alone.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers
  import ExUnit.CaptureLog

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @test_file "test/broken_oaths/diplomacy/war_test.exs"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Each failed test gets its own classification", criterion: 2494 do
    scenario "a confirmed flake and a failure without flake evidence share one gate" do
      given_ "a candidate with two failing tests, only one of which passed at this commit",
             context do
        context = context |> a_promotable_project() |> an_agent_on_the_copy()
        commit_work(context, context.agent_root, "lib/broken_oaths/diplomacy/peace.ex", peace())
        context = Map.put(context, :story, a_promotable_story(context))
        analyzers_are_current(context)
        {:ok, context}
      end

      when_ "the gate ejects the candidate after both tests fail", context do
        promote(context, context.story.number, fresh: true)
        commit = head_of(context, context.gate_root)
        other_scope = %{context.scope | active_working_copy_id: context.running.working_copy_id}

        pass =
          Fixtures.finished_analysis_run_with_findings(other_scope,
            source: "exunit",
            full: true,
            commit: commit,
            failures: [failure("test B")],
            problems: []
          )

        log =
          capture_log([level: :info], fn ->
            the_gate_answers(context, %{"exunit" => [failure("test A"), failure("test B")]})
            what_the_agent_was_told(context)
          end)

        {:ok, Map.merge(context, %{log: log, passing_run: pass})}
      end

      then_ "the log gives both tests separate lines and classifies each by its evidence",
            context do
        lines = String.split(context.log, "\n")
        a = Enum.find(lines, &String.contains?(&1, "test A"))
        b = Enum.find(lines, &String.contains?(&1, "test B"))

        assert a, context.log
        assert b, context.log
        assert a =~ "confirmed flake"
        assert a =~ to_string(context.passing_run.id)
        assert b =~ "not a flake"
        refute b =~ "confirmed flake"
        {:ok, context}
      end
    end
  end

  defp failure(name) do
    %{"file" => @test_file, "line" => 3, "name" => name, "message" => "war declaration failed"}
  end

  defp peace, do: "defmodule BrokenOaths.Diplomacy.Peace do\n  def keep, do: :ok\nend\n"
end
