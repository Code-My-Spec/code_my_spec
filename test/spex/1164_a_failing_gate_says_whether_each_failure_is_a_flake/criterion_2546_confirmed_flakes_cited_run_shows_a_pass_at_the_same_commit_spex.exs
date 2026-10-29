defmodule CodeMySpecSpex.Story1164.Criterion2546Spex do
  @moduledoc """
  Story 1164, criterion 2546: a cited passing run has retained evidence at
  the ejected candidate's exact commit.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @test_file "test/cms_harness/sync_path_test.exs"
  @test_name "test syncs the path"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A confirmed flake cites a passing run at the ejected commit", criterion: 2546 do
    scenario "John looks up the run cited for sync_path_test.exs" do
      given_ "a full exunit run passed sync_path_test.exs at the candidate commit", context do
        context = context |> a_promotable_project() |> an_agent_on_the_copy()
        commit_work(context, context.agent_root, "lib/broken_oaths/diplomacy/peace.ex", peace())
        context = Map.put(context, :story, a_promotable_story(context))
        analyzers_are_current(context)
        promote(context, context.story.number, fresh: true)
        the_gate_is_running(context)

        commit = head_of(context, context.gate_root)
        other_scope = %{context.scope | active_working_copy_id: context.running.working_copy_id}

        Fixtures.finished_analysis_run_with_findings(other_scope,
          source: "exunit",
          full: true,
          commit: commit,
          failures: [],
          problems: []
        )

        {:ok, Map.put(context, :ejected_commit, commit)}
      end

      when_ "the gate ejects the candidate and John looks up its cited run", context do
        log =
          Fixtures.capture_log_at(:info, fn ->
            the_gate_answers_and_fails_rerun(context, %{"exunit" => [failure()]})
            what_the_agent_was_told(context)
          end)

        line = Enum.find(String.split(log, "\n"), &String.contains?(&1, @test_file))
        assert line, log
        assert line =~ "confirmed flake"
        assert [_, run_id] = Regex.run(~r/evidence=(\d+):/, line)

        history =
          Fixtures.retained_analysis_history_entry(context.scope, String.to_integer(run_id))

        {:ok, Map.merge(context, %{line: line, history: history})}
      end

      then_ "the cited run is full, completed at the ejected commit, and records no failure for that test",
            context do
        assert context.history, context.line
        assert context.history.source == "exunit"
        assert context.history.status == :completed
        refute context.history.partial
        assert context.history.completed_commit == context.ejected_commit

        refute Enum.any?(context.history.failures, fn failure ->
                 failure["file"] == @test_file and failure["name"] == @test_name
               end)

        {:ok, context}
      end
    end
  end

  defp failure do
    %{"file" => @test_file, "line" => 3, "name" => @test_name, "message" => "sync failed"}
  end

  defp peace, do: "defmodule BrokenOaths.Diplomacy.Peace do\n  def keep, do: :ok\nend\n"
end
