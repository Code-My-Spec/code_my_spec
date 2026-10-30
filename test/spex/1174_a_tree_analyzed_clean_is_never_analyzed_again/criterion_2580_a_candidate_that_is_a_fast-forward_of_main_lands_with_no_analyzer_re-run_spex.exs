defmodule CodeMySpecSpex.Story1174.Criterion2580Spex do
  @moduledoc """
  Story 1174, criterion 2580: a candidate already containing main merges to the
  tree it was certified on, so the gate runs no analyzer and it lands.
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

  spex "A candidate that is a fast-forward of main lands with no analyzer re-run",
    criterion: 2580 do
    scenario "main has not moved since the candidate was certified on tree T" do
      given_ "a candidate already merged with current main, certified on its tree T", context do
        context =
          context |> a_promotable_project(agent_socket: true) |> an_agent_on_the_copy()

        commit_work(context, context.agent_root, "lib/broken_oaths/diplomacy/peace.ex", peace())
        context = Map.put(context, :story, a_promotable_story(context))
        the_copy_passes(context, ~w(compiler exunit spex credo))

        {:ok,
         Map.merge(context, %{
           candidate: head_of(context, context.agent_root),
           tree: tree_of(context, context.agent_root)
         })}
      end

      when_ "the gate merges it onto main and the result is tree T", context do
        promote(context, context.story.number)
        {:ok, Map.put(context, :outcome, the_promotion_outcome(context))}
      end

      then_ "the gate runs no analyzer and the candidate lands", context do
        assert context.outcome =~ "landed on main", context.outcome
        assert head_of(context, context.running_root) == context.candidate
        assert tree_of(context, context.running_root) == context.tree
        the_gate_is_asked_to_run_nothing(context)
        the_copy_is_asked_to_run_nothing(context)
        {:ok, context}
      end
    end
  end

  defp peace, do: "defmodule BrokenOaths.Diplomacy.Peace do\n  def keep, do: :ok\nend\n"
end
