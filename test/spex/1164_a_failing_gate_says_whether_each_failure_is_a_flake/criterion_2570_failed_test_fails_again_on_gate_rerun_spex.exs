defmodule CodeMySpecSpex.Story1164.Criterion2570Spex do
  @moduledoc """
  Story 1164, criterion 2570: a test that fails again on the gate rerun is a
  real failure, and the candidate is ejected.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers
  import Phoenix.ChannelTest, only: [assert_reply: 4]

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

  spex "A failure that fails again on the rerun is a real failure and ejects the candidate",
    criterion: 2570 do
    scenario "the failed test fails a second time in the gate" do
      given_ "a promotable candidate whose gate will fail one exunit test", context do
        context = context |> a_promotable_project() |> an_agent_on_the_copy()
        commit_work(context, context.agent_root, "lib/broken_oaths/diplomacy/peace.ex", peace())
        context = Map.put(context, :story, a_promotable_story(context))
        analyzers_are_current(context)
        {:ok, Map.put(context, :main_commit, head_of(context, context.running_root))}
      end

      when_ "the gate reruns that failed test and it fails again", context do
        promote(context, context.story.number, fresh: true)
        the_gate_is_running(context)

        {outcome, log} =
          Fixtures.with_log_at(:info, fn ->
            the_gate_answers(context, %{"exunit" => [failure()]})

            assert_receive %Phoenix.Socket.Message{
                             event: "run_analysis",
                             payload: %{"runs" => [%{"run_id" => rerun_id, "source" => "exunit"}]}
                           },
                           10_000

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
                  "execution_status" => "failure",
                  "exit_status" => 2,
                  "stats" => %{"tests" => 1, "failures" => 1},
                  "diagnostics" => [failure()]
                }
              })

            assert_reply ref, :ok, _, 10_000
            what_the_agent_was_told(context)
          end)

        {:ok, Map.merge(context, %{log: log, outcome: outcome})}
      end

      then_ "the failure is classified as real and nothing lands on main", context do
        assert context.log =~ @test_file, context.log
        assert context.log =~ @test_name, context.log
        refute context.log =~ "confirmed flake", context.log
        assert context.outcome =~ "eject", context.outcome
        assert head_of(context, context.running_root) == context.main_commit
        {:ok, context}
      end
    end
  end

  defp failure do
    %{"file" => @test_file, "line" => 3, "name" => @test_name, "message" => "assertion failed"}
  end

  defp peace, do: "defmodule BrokenOaths.Diplomacy.Peace do\n  def keep, do: :ok\nend\n"
end
