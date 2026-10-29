defmodule CodeMySpecSpex.Story1174.Criterion2579Spex do
  @moduledoc """
  Story 1174, criterion 2579: certifying a tree runs only the analyzers it has
  not passed. The agent certifies by asking `start_analysis` for all four.
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

  spex "John's agent ran spex clean, so certifying runs only exunit and credo", criterion: 2579 do
    scenario "spex and compiler passed the tree; exunit and credo never ran" do
      given_ "an agent's tree has passed spex and compiler in full", context do
        context =
          context |> a_promotable_project(agent_socket: true) |> an_agent_on_the_copy()

        commit_work(context, context.agent_root, "lib/broken_oaths/diplomacy/peace.ex", peace())
        the_copy_passes(context, ~w(spex compiler))
        {:ok, context}
      end

      when_ "the agent certifies", context do
        replies = Map.new(~w(compiler credo exunit spex), &{&1, start_analysis(context, &1)})

        requested =
          for _ <- 1..2, do: the_copy_is_asked_to_run(context)["source"]

        {:ok, Map.merge(context, %{replies: replies, requested: requested})}
      end

      then_ "only exunit and credo are run", context do
        assert Enum.sort(context.requested) == ~w(credo exunit)
        the_copy_is_asked_to_run_nothing(context)

        for passed <- ~w(compiler spex),
            do: assert(context.replies[passed] =~ "#{passed} already passed this tree")

        for ran <- ~w(credo exunit), do: assert(context.replies[ran] =~ "admitted")
        {:ok, context}
      end
    end
  end

  defp peace, do: "defmodule BrokenOaths.Diplomacy.Peace do\n  def keep, do: :ok\nend\n"
end
