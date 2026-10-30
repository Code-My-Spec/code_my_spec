defmodule CodeMySpecSpex.Story1174.Criterion2576Spex do
  @moduledoc """
  Story 1174, criterion 2576: a change whose tree has passed all four analyzers
  in full is certified, and its promotion is queued.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
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

  spex "An agent's change is certified once all four analyzers have passed its tree",
    criterion: 2576 do
    scenario "compiler, exunit, spex and credo passed the copy's tree in full" do
      given_ "a coding agent's copy at a clean commit whose tree passed all four", context do
        context =
          context |> a_promotable_project(agent_socket: true) |> an_agent_on_the_copy()

        commit_work(context, context.agent_root, "lib/broken_oaths/diplomacy/peace.ex", peace())
        context = Map.put(context, :story, a_promotable_story(context))
        the_copy_passes(context, ~w(compiler exunit spex credo))
        {:ok, context}
      end

      when_ "the agent promotes", context do
        {:ok, Map.put(context, :reply, promote(context, context.story.number))}
      end

      then_ "the promotion is accepted as certified", context do
        text = response_text(context.reply)
        assert text =~ "Queued for promotion", text
        refute text =~ "not certified", text
        {:ok, context}
      end
    end
  end

  defp peace, do: "defmodule BrokenOaths.Diplomacy.Peace do\n  def keep, do: :ok\nend\n"
end
