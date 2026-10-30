defmodule CodeMySpecSpex.Story1174.Criterion2585Spex do
  @moduledoc """
  Story 1174, criterion 2585: a change outside the tree that affects results
  makes the tree unanalyzed.

  This project has no path dependencies (`client_utils` is pinned from Hex), so
  nothing outside the tree is fingerprinted. A `client_utils` move is answered
  by asking for fresh runs, which is what the agent does here.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers
  import CodeMySpecSpex.TreeCertificationHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @sources ~w(compiler credo exunit spex)

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A client_utils change forces fresh runs on an unchanged tree", criterion: 2585 do
    scenario "client_utils moved after tree T passed every analyzer" do
      given_ "tree T passed all four analyzers against the client_utils it had", context do
        context =
          context |> a_promotable_project(agent_socket: true) |> an_agent_on_the_copy()

        commit_work(context, context.agent_root, "lib/broken_oaths/diplomacy/peace.ex", peace())
        the_copy_passes(context, @sources)
        {:ok, context}
      end

      when_ "the agent certifies tree T asking for fresh runs", context do
        replies = Map.new(@sources, &{&1, start_analysis(context, &1, %{fresh: true})})
        requested = for _ <- @sources, do: the_copy_is_asked_to_run(context)["source"]
        {:ok, Map.merge(context, %{replies: replies, requested: requested})}
      end

      then_ "every analyzer is run again on T", context do
        assert Enum.sort(context.requested) == @sources

        for source <- @sources do
          refute context.replies[source] =~ "already passed", context.replies[source]
          assert context.replies[source] =~ "admitted", context.replies[source]
        end

        {:ok, context}
      end
    end
  end

  defp peace, do: "defmodule BrokenOaths.Diplomacy.Peace do\n  def keep, do: :ok\nend\n"
end
