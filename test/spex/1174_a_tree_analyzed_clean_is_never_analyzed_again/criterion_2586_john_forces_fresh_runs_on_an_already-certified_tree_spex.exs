defmodule CodeMySpecSpex.Story1174.Criterion2586Spex do
  @moduledoc """
  Story 1174, criterion 2586: a promote with `fresh: true` runs every analyzer
  again at the gate, though the tree already passed them all.
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

  spex "John forces fresh runs on an already-certified tree", criterion: 2586 do
    scenario "a fast-forward candidate whose tree passed every analyzer" do
      given_ "tree T has passed every analyzer", context do
        context =
          context |> a_promotable_project(agent_socket: true) |> an_agent_on_the_copy()

        commit_work(context, context.agent_root, "lib/broken_oaths/diplomacy/peace.ex", peace())
        context = Map.put(context, :story, a_promotable_story(context))
        the_copy_passes(context, ~w(compiler exunit spex credo))
        {:ok, Map.put(context, :tree, tree_of(context, context.agent_root))}
      end

      when_ "John promotes it asking for fresh runs", context do
        promote(context, context.story.number, fresh: true)
        requested = the_gate_is_running(context)
        gate_tree = tree_of(context, context.gate_root)
        the_gate_answers(context)
        outcome = the_promotion_outcome(context)

        {:ok, Map.merge(context, %{requested: requested, gate_tree: gate_tree, outcome: outcome})}
      end

      then_ "every analyzer is run again on T before it lands", context do
        assert context.gate_tree == context.tree
        assert context.requested == ~w(compiler credo exunit spex)
        assert context.outcome =~ "landed on main", context.outcome
        assert tree_of(context, context.running_root) == context.tree
        {:ok, context}
      end
    end
  end

  defp peace, do: "defmodule BrokenOaths.Diplomacy.Peace do\n  def keep, do: :ok\nend\n"
end
