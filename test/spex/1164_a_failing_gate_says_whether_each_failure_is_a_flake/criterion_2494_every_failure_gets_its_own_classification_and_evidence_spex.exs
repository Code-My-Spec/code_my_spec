defmodule CodeMySpecSpex.Story1164.Criterion2494Spex do
  @moduledoc """
  Story 1164, criterion 2494: an ejection distinguishes a real failure from
  a test that passed on the gate's targeted rerun.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers
  import Phoenix.ChannelTest, only: [assert_reply: 4]

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
    scenario "one test passes on rerun while the other fails again" do
      given_ "a candidate whose gate fails two tests", context do
        context = context |> a_promotable_project() |> an_agent_on_the_copy()
        commit_work(context, context.agent_root, "lib/broken_oaths/diplomacy/peace.ex", peace())
        context = Map.put(context, :story, a_promotable_story(context))
        analyzers_are_current(context)
        {:ok, context}
      end

      when_ "the gate rerun passes test A and fails test B", context do
        promote(context, context.story.number, fresh: true)
        the_gate_is_running(context)

        {{outcome, rerun_id}, log} =
          Fixtures.with_log_at(:info, fn ->
            the_gate_answers(context, %{"exunit" => [failure("test A"), failure("test B")]})

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
                  "stats" => %{"tests" => 2, "failures" => 1},
                  "diagnostics" => [failure("test B")]
                }
              })

            assert_reply ref, :ok, _, 10_000
            {what_the_agent_was_told(context), rerun_id}
          end)

        {:ok, Map.merge(context, %{log: log, outcome: outcome, rerun_id: rerun_id})}
      end

      then_ "the ejection logs a confirmed flake and a real failure separately", context do
        lines =
          context.log |> String.split("\n") |> Enum.filter(&String.contains?(&1, "evidence="))

        a = Enum.find(lines, &String.contains?(&1, "#{@test_file}: test A"))
        b = Enum.find(lines, &String.contains?(&1, "#{@test_file}: test B"))

        assert a, context.log
        assert b, context.log
        assert a =~ "confirmed flake; rerun=#{context.rerun_id}"
        assert b =~ "not a flake; rerun=#{context.rerun_id} failed again"
        refute b =~ "confirmed flake"
        assert context.outcome =~ "was taken out of the queue and nothing of it landed"
        {:ok, context}
      end
    end
  end

  defp failure(name) do
    %{"file" => @test_file, "line" => 3, "name" => name, "message" => "war declaration failed"}
  end

  defp peace, do: "defmodule BrokenOaths.Diplomacy.Peace do\n  def keep, do: :ok\nend\n"
end
