defmodule CodeMySpecSpex.Story1091.Criterion1974Spex do
  @moduledoc """
  Story 1091 — Issues get a dedicated agent who sees them through.
  Criterion 1974 — A passing QA attempt sends the team to promote; the landing resolves the issue and frees the team.

  Rule: an issue resolves only when its fix is on main and QA has passed it.
  A pass hands the coder the promotion; the queue's landing resolves the
  issue and frees both teammates for main's next assignment.
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

  spex "A passing QA attempt sends the team to promote; the landing resolves the issue",
    criterion: 1974 do
    scenario "QA passes the fix, the coder promotes it, and it lands" do
      given_ "a team whose coder has fixed its assigned issue", context do
        context =
          context
          |> a_promotable_project()
          |> an_issue_assigned_to_the_team()
          |> the_coder_fixes_it("lib/broken_oaths/diplomacy/notify.ex", notify())

        {:ok, analyzers_are_current(context)}
      end

      when_ "QA passes the fix", context do
        {:ok, qa_passes_it(context)}
      end

      then_ "the issue is not resolved yet", context do
        refute the_issue(context) =~ "**Status:** resolved",
               "a fix that is not on main was resolved on QA's word alone"

        {:ok, context}
      end

      then_ "the coder is offered the promotion", context do
        assert the_coder_is_offered(context) =~ "requirement_name=`promote_issue`"
        {:ok, context}
      end

      when_ "the coder promotes it, and the queue lands it", context do
        answer = the_coder_promotes_it(context)
        assert answer =~ "Queued for promotion", answer
        {:ok, Map.put(context, :told, what_was_told(context.coder.id))}
      end

      then_ "the fix is on main", context do
        assert context.told =~ "landed on main", context.told
        assert exists?(context.running_root, "lib/broken_oaths/diplomacy/notify.ex")
        {:ok, context}
      end

      then_ "the issue is resolved and the team is free", context do
        assert the_issue(context) =~ "**Status:** resolved"
        assert the_team_is_free?(context), "the team is still bound to a resolved issue"
        {:ok, context}
      end
    end
  end

  defp notify,
    do: "defmodule BrokenOaths.Diplomacy.Notify do\n  def deliver, do: :delivered\nend\n"
end
