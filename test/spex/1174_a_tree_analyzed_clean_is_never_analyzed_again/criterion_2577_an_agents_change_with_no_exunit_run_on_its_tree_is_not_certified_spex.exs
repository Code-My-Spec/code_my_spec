defmodule CodeMySpecSpex.Story1174.Criterion2577Spex do
  @moduledoc """
  Story 1174, criterion 2577: a tree with no exunit pass is not certified, and
  the refusal names exunit and nothing else.
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

  spex "An agent's change with no exunit run on its tree is not certified", criterion: 2577 do
    scenario "compiler, spex and credo passed the copy's tree; exunit never ran" do
      given_ "a coding agent's copy whose tree has passed all but exunit", context do
        context =
          context |> a_promotable_project(agent_socket: true) |> an_agent_on_the_copy()

        commit_work(context, context.agent_root, "lib/broken_oaths/diplomacy/peace.ex", peace())
        context = Map.put(context, :story, a_promotable_story(context))
        the_copy_passes(context, ~w(compiler spex credo))
        {:ok, context}
      end

      when_ "the agent promotes", context do
        {:ok, Map.put(context, :reply, promote(context, context.story.number))}
      end

      then_ "the promotion is refused, naming exunit as missing for that tree", context do
        text = response_text(context.reply)
        assert text =~ "is not certified: exunit has not passed its tree", text
        refute text =~ "Queued for promotion", text

        for passed <- ~w(compiler spex credo),
            do: refute(text =~ "certified: #{passed}", text)

        {:ok, context}
      end
    end
  end

  defp peace, do: "defmodule BrokenOaths.Diplomacy.Peace do\n  def keep, do: :ok\nend\n"
end
