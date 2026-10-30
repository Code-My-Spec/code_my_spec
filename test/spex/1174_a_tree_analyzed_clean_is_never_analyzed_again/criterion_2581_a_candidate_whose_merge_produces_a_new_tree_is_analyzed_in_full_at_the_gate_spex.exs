defmodule CodeMySpecSpex.Story1174.Criterion2581Spex do
  @moduledoc """
  Story 1174, criterion 2581: a certified candidate that main moved past merges
  to a tree no analyzer has passed, so the gate runs all four before it lands.
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

  spex "A candidate whose merge produces a new tree is analyzed in full at the gate",
    criterion: 2581 do
    scenario "main took another team's treaty after the candidate was certified" do
      given_ "a certified candidate that main has moved past", context do
        context =
          context |> a_promotable_project(agent_socket: true) |> an_agent_on_the_copy()

        commit_work(context, context.agent_root, "lib/broken_oaths/diplomacy/peace.ex", peace())
        context = Map.put(context, :story, a_promotable_story(context))
        the_copy_passes(context, ~w(compiler exunit spex credo))

        commit_work(
          context,
          context.running_root,
          "lib/broken_oaths/diplomacy/treaty.ex",
          treaty()
        )

        {:ok, Map.put(context, :certified_tree, tree_of(context, context.agent_root))}
      end

      when_ "the gate merges it onto main and the result is a tree no analyzer has passed",
            context do
        promote(context, context.story.number)
        requested = the_gate_is_running(context)
        merged_tree = tree_of(context, context.gate_root)
        the_gate_answers(context)
        outcome = the_promotion_outcome(context)

        {:ok,
         Map.merge(context, %{requested: requested, merged_tree: merged_tree, outcome: outcome})}
      end

      then_ "the gate runs every analyzer on that tree before landing it", context do
        assert context.merged_tree != context.certified_tree
        assert context.requested == ~w(compiler credo exunit spex)
        assert context.outcome =~ "landed on main", context.outcome
        assert tree_of(context, context.running_root) == context.merged_tree
        {:ok, context}
      end
    end
  end

  defp peace, do: "defmodule BrokenOaths.Diplomacy.Peace do\n  def keep, do: :ok\nend\n"
end
