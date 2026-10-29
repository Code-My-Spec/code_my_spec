defmodule CodeMySpecSpex.Story1165.Criterion2496Spex do
  @moduledoc """
  Story 1165, criterion 2496: a flake from an ejected promotion does not
  become a system alert in main's next check-in.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
  import Phoenix.ChannelTest, only: [assert_reply: 4]

  alias CodeMySpec.ToolLibrary
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

  spex "Main's check-in carries no system alert about a promotion flake", criterion: 2496 do
    scenario "a promotion with a confirmed flake is ejected for another gate failure" do
      given_ "a promotion was ejected after a failed test passed its gate rerun", context do
        context = context |> a_promotable_project() |> an_agent_on_the_copy()
        commit_work(context, context.agent_root, "lib/broken_oaths/diplomacy/peace.ex", peace())
        context = Map.put(context, :story, a_promotable_story(context))
        analyzers_are_current(context)
        promote(context, context.story.number, fresh: true)
        the_gate_is_running(context)

        the_gate_answers(context, %{"exunit" => [failure(), other_failure()]})

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
              "diagnostics" => [other_failure()]
            }
          })

        assert_reply(ref, :ok, _, 10_000)
        outcome = what_the_agent_was_told(context)
        assert outcome =~ "taken out of the queue", outcome
        {:ok, context}
      end

      when_ "main receives its next check-in", context do
        frame = %{current_scope: context.scope, scope: context.scope}
        reply = ToolLibrary.run("check_in", %{}, frame)
        assert match?({:ok, _}, reply), response_text(reply)
        {:ok, Map.put(context, :check_in, response_text(reply))}
      end

      then_ "the check-in carries no system alert about the flake", context do
        assert context.check_in =~ "Check-in."

        refute Regex.match?(~r/system alert.{0,300}war_test\.exs/is, context.check_in),
               context.check_in

        refute Regex.match?(~r/system alert.{0,300}test declares war/is, context.check_in),
               context.check_in

        {:ok, context}
      end
    end
  end

  defp failure do
    %{"file" => @test_file, "line" => 3, "name" => @test_name, "message" => "assertion failed"}
  end

  defp other_failure do
    %{
      "file" => @test_file,
      "line" => 4,
      "name" => "test ends the war",
      "message" => "assertion failed"
    }
  end

  defp peace, do: "defmodule BrokenOaths.Diplomacy.Peace do\n  def keep, do: :ok\nend\n"
end
