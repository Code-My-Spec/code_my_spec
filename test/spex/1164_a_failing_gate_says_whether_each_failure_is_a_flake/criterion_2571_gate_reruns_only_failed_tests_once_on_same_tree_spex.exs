defmodule CodeMySpecSpex.Story1164.Criterion2571Spex do
  @moduledoc """
  Story 1164, criterion 2571: the gate reruns only failed tests, once, on
  the same commit and tree.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers
  import Phoenix.ChannelTest, only: [assert_reply: 4]

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @failed_file "test/broken_oaths/diplomacy/war_test.exs"
  @failed_name "test declares war"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The gate reruns only failed tests once on the same commit and tree", criterion: 2571 do
    scenario "one exunit test fails in the full gate sweep" do
      given_ "a promotable candidate with a clean gate checkout", context do
        context = context |> a_promotable_project() |> an_agent_on_the_copy()
        commit_work(context, context.agent_root, "lib/broken_oaths/diplomacy/peace.ex", peace())
        context = Map.put(context, :story, a_promotable_story(context))
        analyzers_are_current(context)
        {:ok, context}
      end

      when_ "the full gate sweep reports one failed test", context do
        promote(context, context.story.number, fresh: true)
        the_gate_is_running(context)
        commit = head_of(context, context.gate_root)
        {tree, 0} = git(context, context.gate_root, ["rev-parse", "HEAD^{tree}"])
        {status, 0} = git(context, context.gate_root, ["status", "--porcelain"])
        assert status == ""

        the_gate_answers(context, %{"exunit" => [failure()]})

        assert_receive %Phoenix.Socket.Message{
                         event: "run_analysis",
                         payload: %{
                           "runs" => [%{"run_id" => rerun_id, "source" => "exunit"} = rerun]
                         }
                       },
                       10_000

        {:ok,
         Map.merge(context, %{
           commit: commit,
           tree: String.trim(tree),
           rerun_id: rerun_id,
           rerun: rerun
         })}
      end

      then_ "the request selects failed tests and a second request never follows", context do
        assert "#{@failed_file}:3" in context.rerun["args"]
        assert Enum.all?(context.rerun["args"], &String.starts_with?(&1, @failed_file <> ":"))
        refute "--failed" in context.rerun["args"]
        assert head_of(context, context.gate_root) == context.commit
        {tree, 0} = git(context, context.gate_root, ["rev-parse", "HEAD^{tree}"])
        {status, 0} = git(context, context.gate_root, ["status", "--porcelain"])
        assert String.trim(tree) == context.tree
        assert status == ""

        Phoenix.ChannelTest.push(context.gate_socket, "analysis_started", %{
          "run_id" => context.rerun_id,
          "start_commit" => context.commit,
          "start_tree_dirty" => false
        })

        ref =
          Phoenix.ChannelTest.push(context.gate_socket, "analysis_result", %{
            "run_id" => context.rerun_id,
            "source" => "exunit",
            "status" => "ok",
            "completed_commit" => context.commit,
            "result" => %{
              "execution_status" => "failure",
              "exit_status" => 2,
              "stats" => %{"tests" => 1, "failures" => 1},
              "diagnostics" => [failure()]
            }
          })

        assert_reply ref, :ok, _, 10_000

        assert what_the_agent_was_told(context) =~
                 "was taken out of the queue and nothing of it landed"

        refute_receive %Phoenix.Socket.Message{event: "run_analysis"}, 500
        {:ok, context}
      end
    end
  end

  defp failure do
    %{
      "file" => @failed_file,
      "line" => 3,
      "name" => @failed_name,
      "message" => "assertion failed"
    }
  end

  defp peace, do: "defmodule BrokenOaths.Diplomacy.Peace do\n  def keep, do: :ok\nend\n"
end
