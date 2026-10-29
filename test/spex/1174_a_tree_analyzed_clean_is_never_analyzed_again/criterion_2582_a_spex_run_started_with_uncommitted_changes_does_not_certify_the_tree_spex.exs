defmodule CodeMySpecSpex.Story1174.Criterion2582Spex do
  @moduledoc """
  Story 1174, criterion 2582: spex run over uncommitted changes certifies
  nothing, even once exactly those changes are committed.
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

  spex "A spex run started with uncommitted changes does not certify the tree", criterion: 2582 do
    scenario "the agent ran spex before committing the peace module" do
      given_ "an agent ran spex while its copy had uncommitted changes", context do
        context =
          context |> a_promotable_project(agent_socket: true) |> an_agent_on_the_copy()

        commit_work(context, context.agent_root, "lib/broken_oaths/diplomacy/war.ex", war(":v1"))
        write(context.agent_root, "lib/broken_oaths/diplomacy/war.ex", war(":v2"))
        start_analysis(context, "spex")
        the_harness_answers(context, the_copy_is_asked_to_run(context), dirty: true)
        {:ok, context}
      end

      when_ "the agent commits and certifies", context do
        {_, 0} = git(context, context.agent_root, ["commit", "-qam", "Declare it twice"])
        reply = start_analysis(context, "spex")
        {:ok, Map.merge(context, %{reply: reply, run: the_copy_is_asked_to_run(context)})}
      end

      then_ "spex is run again on the committed tree", context do
        refute context.reply =~ "already passed", context.reply
        assert context.reply =~ "Run #{context.run["run_id"]} admitted", context.reply
        assert context.run["source"] == "spex"
        assert context.run["args"] == []
        {:ok, context}
      end
    end
  end
end
