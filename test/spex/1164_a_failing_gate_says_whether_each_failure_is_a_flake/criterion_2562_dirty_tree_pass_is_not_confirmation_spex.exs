defmodule CodeMySpecSpex.Story1164.Criterion2562Spex do
  @moduledoc """
  Story 1164, criterion 2562: a pass on a dirty tree at the same commit does
  not confirm a flake.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @test_file "test/broken_oaths/diplomacy/war_test.exs"
  @test_name "test declares war"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A dirty-tree pass at the same commit does not confirm a flake", criterion: 2562 do
    scenario "another copy passed only with uncommitted edits" do
      given_ "a promotable candidate and a test that passed on a dirty tree", context do
        context = context |> a_promotable_project() |> an_agent_on_the_copy()
        commit_work(context, context.agent_root, "lib/broken_oaths/diplomacy/peace.ex", peace())
        context = Map.put(context, :story, a_promotable_story(context))
        analyzers_are_current(context)
        {:ok, context}
      end

      when_ "the gate fails that test at the same commit", context do
        promote(context, context.story.number, fresh: true)
        the_gate_is_running(context)
        commit = head_of(context, context.gate_root)
        other_scope = %{context.scope | active_working_copy_id: context.running.working_copy_id}

        pass =
          Fixtures.finished_analysis_run_with_findings(other_scope,
            source: "exunit",
            full: true,
            commit: commit,
            dirty: true,
            failures: [],
            problems: []
          )

        log =
          Fixtures.capture_log_at(:info, fn ->
            the_gate_answers_and_fails_rerun(context, %{"exunit" => [failure()]})
            what_the_agent_was_told(context)
          end)

        {:ok, Map.merge(context, %{log: log, pass: pass})}
      end

      then_ "the dirty pass is not cited as confirmation", context do
        line = Enum.find(String.split(context.log, "\n"), &String.contains?(&1, @test_name))
        assert line, context.log
        assert line =~ @test_file
        refute line =~ "confirmed flake"
        refute line =~ "pass_run=#{context.pass.id}"
        {:ok, context}
      end
    end
  end

  defp failure do
    %{
      "file" => @test_file,
      "line" => 3,
      "name" => @test_name,
      "message" => "war declaration failed"
    }
  end

  defp peace, do: "defmodule BrokenOaths.Diplomacy.Peace do\n  def keep, do: :ok\nend\n"
end
