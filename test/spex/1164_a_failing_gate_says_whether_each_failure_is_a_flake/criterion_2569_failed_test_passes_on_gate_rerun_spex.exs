defmodule CodeMySpecSpex.Story1164.Criterion2569Spex do
  @moduledoc """
  Story 1164, criterion 2569: a gate failure that passes when the gate reruns
  its failed tests is a confirmed flake, and the candidate lands.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers
  import Phoenix.ChannelTest, only: [assert_reply: 4]

  alias CodeMySpec.ExecutionContexts
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

  spex "A failed test that passes on the gate rerun is a confirmed flake and the candidate lands",
    criterion: 2569 do
    scenario "the gate reruns its failed test and it passes" do
      given_ "a promotable candidate whose gate will fail one exunit test", context do
        context = context |> a_promotable_project() |> an_agent_on_the_copy()
        commit_work(context, context.agent_root, "lib/broken_oaths/diplomacy/peace.ex", peace())
        commit_work(context, context.agent_root, @test_file, flaky_test())
        context = Map.put(context, :story, a_promotable_story(context))
        analyzers_are_current(context)
        {:ok, Map.put(context, :candidate_commit, head_of(context, context.agent_root))}
      end

      when_ "the gate's failed test passes on its requested rerun", context do
        promote(context, context.story.number, fresh: true)
        the_gate_is_running(context)

        {outcome, log} =
          Fixtures.with_log_at(:info, fn ->
            {first_output, first_status} = run_gate_test(context)
            assert first_status != 0, first_output
            assert first_output =~ "1 test, 1 failure", first_output
            the_gate_answers(context, %{"exunit" => [failure()]})

            assert_receive %Phoenix.Socket.Message{
                             event: "run_analysis",
                             payload: %{"runs" => [%{"run_id" => rerun_id, "source" => "exunit"}]}
                           },
                           10_000

            {rerun_output, rerun_status} = run_gate_test(context)
            assert rerun_status == 0, rerun_output
            assert rerun_output =~ "1 test, 0 failures", rerun_output
            commit = head_of(context, context.gate_root)

            Phoenix.ChannelTest.push(context.gate_socket, "analysis_started", %{
              "run_id" => rerun_id,
              "start_commit" => commit,
              "start_tree_dirty" => false
            })

            ref =
              Phoenix.ChannelTest.push(context.gate_socket, "analysis_result", %{
                "run_id" => rerun_id,
                "source" => "exunit",
                "status" => "ok",
                "completed_commit" => commit,
                "result" => %{
                  "execution_status" => "success",
                  "exit_status" => 0,
                  "stats" => %{"tests" => 1, "failures" => 0},
                  "diagnostics" => []
                }
              })

            assert_reply ref, :ok, _, 10_000
            what_the_agent_was_told(context)
          end)

        {:ok, Map.merge(context, %{log: log, outcome: outcome})}
      end

      then_ "the failed test is confirmed as a flake and the candidate lands", context do
        assert context.log =~ @test_file, context.log
        assert context.log =~ @test_name, context.log
        assert context.log =~ "confirmed flake", context.log
        assert context.outcome =~ "landed on main", context.outcome
        assert head_of(context, context.running_root) == context.candidate_commit
        {:ok, context}
      end
    end
  end

  defp failure do
    %{"file" => @test_file, "line" => 4, "name" => @test_name, "message" => "assertion failed"}
  end

  defp run_gate_test(context) do
    ExecutionContexts.cmd(context.execution_context, "elixir", [@test_file],
      cd: context.gate_root,
      stderr_to_stdout: true
    )
  end

  defp flaky_test do
    """
    ExUnit.start()
    defmodule BrokenOaths.Diplomacy.WarTest do
      use ExUnit.Case
      test "declares war" do
        marker = Path.join(File.cwd!(), "_build/war_test_ran")
        File.mkdir_p!(Path.dirname(marker))
        ran_before = File.exists?(marker)
        File.write!(marker, "ran")
        assert ran_before
      end
    end
    """
  end

  defp peace, do: "defmodule BrokenOaths.Diplomacy.Peace do\n  def keep, do: :ok\nend\n"
end
