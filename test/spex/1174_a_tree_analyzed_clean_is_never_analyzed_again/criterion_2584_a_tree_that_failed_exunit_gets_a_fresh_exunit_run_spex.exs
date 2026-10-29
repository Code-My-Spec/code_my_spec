defmodule CodeMySpecSpex.Story1174.Criterion2584Spex do
  @moduledoc """
  Story 1174, criterion 2584: a failed run is never reused, so certifying a tree
  that failed exunit runs exunit again.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers
  import CodeMySpecSpex.TreeCertificationHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A tree that failed exunit gets a fresh exunit run", criterion: 2584 do
    scenario "the war test failed on tree T" do
      given_ "exunit failed on tree T", context do
        context =
          context |> a_promotable_project(agent_socket: true) |> an_agent_on_the_copy()

        commit_work(context, context.agent_root, "lib/broken_oaths/diplomacy/peace.ex", peace())
        start_analysis(context, "exunit")

        the_harness_answers(context, the_copy_is_asked_to_run(context),
          findings: [a_failing_test("test/broken_oaths/diplomacy/war_test.exs")]
        )

        {:ok, context}
      end

      when_ "the agent certifies tree T again", context do
        reply = start_analysis(context, "exunit")
        {:ok, Map.merge(context, %{reply: reply, run: the_copy_is_asked_to_run(context)})}
      end

      then_ "exunit is run again on T", context do
        refute context.reply =~ "already passed", context.reply
        assert context.reply =~ "Run #{context.run["run_id"]} admitted", context.reply
        assert context.run["source"] == "exunit"
        assert context.run["args"] == []
        {:ok, context}
      end
    end
  end

  defp peace, do: "defmodule BrokenOaths.Diplomacy.Peace do\n  def keep, do: :ok\nend\n"
end
