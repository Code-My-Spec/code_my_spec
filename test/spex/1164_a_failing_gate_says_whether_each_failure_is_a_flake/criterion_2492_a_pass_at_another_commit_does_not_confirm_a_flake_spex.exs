defmodule CodeMySpecSpex.Story1164.Criterion2492Spex do
  @moduledoc """
  Story 1164: A failing gate reports the evidence for each flaky test.
  Criterion 2492: A pass without full same-commit coverage cannot confirm a flake.
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

  spex "A pass at another commit does not confirm a flake", criterion: 2492 do
    scenario "the only full pass is at an earlier commit, and a same-commit pass is partial" do
      given_ "a promotable candidate", context do
        context = context |> a_promotable_project() |> an_agent_on_the_copy()
        commit_work(context, context.agent_root, "lib/broken_oaths/diplomacy/peace.ex", peace())
        context = Map.put(context, :story, a_promotable_story(context))
        analyzers_are_current(context)
        {:ok, context}
      end

      when_ "the gate's full exunit run fails the test", context do
        promote(context, context.story.number, fresh: true)
        commit = head_of(context, context.gate_root)
        other_scope = %{context.scope | active_working_copy_id: context.running.working_copy_id}

        Fixtures.finished_analysis_run_with_findings(other_scope,
          source: "exunit",
          full: true,
          commit: head_of(context, context.running_root),
          failures: [],
          problems: []
        )

        Fixtures.finished_analysis_run_with_findings(other_scope,
          source: "exunit",
          partial: true,
          commit: commit,
          failures: [],
          problems: []
        )

        log =
          capture_log([level: :info], fn ->
            the_gate_answers(context, %{"exunit" => [failure()]})
            what_the_agent_was_told(context)
          end)

        {:ok, Map.put(context, :log, log)}
      end

      then_ "the failing test has no confirmed-flake claim", context do
        line = Enum.find(String.split(context.log, "\n"), &String.contains?(&1, @name))
        assert line, context.log
        assert line =~ @test_file
        assert line =~ "not a flake"
        refute line =~ "confirmed flake"
        {:ok, context}
      end
    end
  end

  defp failure do
    %{"file" => @test_file, "line" => 3, "name" => @name, "message" => "war declaration failed"}
  end

  defp peace, do: "defmodule BrokenOaths.Diplomacy.Peace do\n  def keep, do: :ok\nend\n"
end
