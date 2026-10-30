defmodule CodeMySpecSpex.Story1174.Criterion2578Spex do
  @moduledoc """
  Story 1174, criterion 2578: spex that passed tree T at one commit answers for
  another commit with the same tree, and is not run again.
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

  spex "A tree spex passed on one copy is not re-run when another commit has the same tree",
    criterion: 2578 do
    scenario "commit B only rewords commit A, so both have tree T" do
      given_ "spex passed in full on tree T at commit A, and commit B has tree T", context do
        context =
          context |> a_promotable_project(agent_socket: true) |> an_agent_on_the_copy()

        commit_work(context, context.agent_root, "lib/broken_oaths/diplomacy/peace.ex", peace())
        commit_a = head_of(context, context.agent_root)
        tree = tree_of(context, context.agent_root)
        %{"spex" => run_id} = the_copy_passes(context, ["spex"])

        {_, 0} =
          git(context, context.agent_root, ["commit", "-q", "--amend", "-m", "Keep the peace"])

        assert head_of(context, context.agent_root) != commit_a
        assert tree_of(context, context.agent_root) == tree
        {:ok, Map.put(context, :spex_run_id, run_id)}
      end

      when_ "the agent certifies commit B", context do
        {:ok, Map.put(context, :reply, start_analysis(context, "spex"))}
      end

      then_ "spex is not run again and its earlier run answers for T", context do
        assert context.reply =~ "spex already passed this tree in run #{context.spex_run_id}",
               context.reply

        assert context.reply =~ "Nothing was queued", context.reply
        the_copy_is_asked_to_run_nothing(context)
        {:ok, context}
      end
    end
  end

  defp peace, do: "defmodule BrokenOaths.Diplomacy.Peace do\n  def keep, do: :ok\nend\n"
end
