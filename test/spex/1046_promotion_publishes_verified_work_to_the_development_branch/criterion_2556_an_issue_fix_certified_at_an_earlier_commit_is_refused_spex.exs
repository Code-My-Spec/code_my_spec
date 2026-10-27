defmodule CodeMySpecSpex.Story1046.Criterion2556Spex do
  @moduledoc """
  Story 1046 — Promotion publishes verified work to the development branch.
  Criterion 2556 — An issue fix certified at an earlier commit is refused.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IssuePromotionHelpers
  import CodeMySpecSpex.PromotionHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An issue fix certified at an earlier commit is refused", criterion: 2556 do
    scenario "the issue's QA-passed fix is followed by an uncertified commit" do
      given_ "a team has fixed an assigned issue and QA has passed its certified commit",
             context do
        context =
          context
          |> a_promotable_project()
          |> an_issue_assigned_to_the_team()
          |> the_coder_fixes_it("lib/broken_oaths/diplomacy/notify.ex", notify())
          |> qa_passes_it()

        {:ok, Map.put(context, :certified_head, head_of(context, context.agent_root))}
      end

      given_ "the team makes another commit without certifying the new HEAD", context do
        commit_work(
          context,
          context.agent_root,
          "lib/broken_oaths/diplomacy/treaty.ex",
          treaty()
        )

        refute head_of(context, context.agent_root) == context.certified_head
        {:ok, context}
      end

      when_ "the coder promotes the issue fix without naming a story", context do
        context = Map.put(context, :agent_id, context.coder.id)
        {:ok, Map.put(context, :response, promote(context, nil))}
      end

      then_ "promotion is refused because certification belongs to the earlier commit", context do
        text = response_text(context.response)
        assert context.response.isError, text
        assert text =~ "certif", text
        refute text =~ "Queued for promotion", text
        {:ok, context}
      end
    end
  end

  defp notify,
    do: "defmodule BrokenOaths.Diplomacy.Notify do\n  def deliver, do: :delivered\nend\n"
end
