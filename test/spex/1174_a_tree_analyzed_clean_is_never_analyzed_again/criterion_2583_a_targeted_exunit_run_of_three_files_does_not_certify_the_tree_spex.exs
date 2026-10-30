defmodule CodeMySpecSpex.Story1174.Criterion2583Spex do
  @moduledoc """
  Story 1174, criterion 2583: a clean exunit run of three test files covers part
  of the suite, so certifying the tree still asks for a full run.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers
  import CodeMySpecSpex.TreeCertificationHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @files ~w(
    test/broken_oaths/diplomacy/war_test.exs
    test/broken_oaths/diplomacy/peace_test.exs
    test/broken_oaths/diplomacy/treaty_test.exs
  )

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A targeted exunit run of three files does not certify the tree", criterion: 2583 do
    scenario "the agent ran exunit on the three diplomacy tests" do
      given_ "an agent ran exunit on three test files of its tree", context do
        context =
          context |> a_promotable_project(agent_socket: true) |> an_agent_on_the_copy()

        commit_work(context, context.agent_root, "lib/broken_oaths/diplomacy/peace.ex", peace())
        start_analysis(context, "exunit", %{paths: @files})
        targeted = the_copy_is_asked_to_run(context)
        assert targeted["args"] == @files
        the_harness_answers(context, targeted)
        {:ok, context}
      end

      when_ "the agent certifies", context do
        reply = start_analysis(context, "exunit")
        {:ok, Map.merge(context, %{reply: reply, run: the_copy_is_asked_to_run(context)})}
      end

      then_ "a full exunit run is required for the tree", context do
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
