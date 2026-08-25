defmodule CodeMySpecSpex.Story964.Criterion2942Spex do
  @moduledoc """
  Story 964 — I approve an epic and it gets built somewhere else.
  Criterion 2942 — I watch the epic take shape and approve it where it is.

  Rule: Approving an epic happens on the epics screen, which the main agent
  changes as it works.

  John's call, and it settles a question that would otherwise have two answers.
  The proposal is made in conversation, so approving in the chat is the obvious
  route — and then the epics screen would be showing state it cannot change, and
  an epic approved in chat that still reads "proposed" on the page is worse than
  having one route.

  One place the answer lives. The agent mutates the screen as it groups stories;
  the control that approves is on the epic it made.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.EpicHelpers
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Approving an epic happens on the epics screen, which the main agent changes as it works" do
    scenario "I watch the epic take shape and approve it where it is" do
      given_ :synced_context_component

      given_ "I am looking at my project's epics", context do
        {:ok, live, html} = live(context.conn, ~p"/app/projects/#{context.project.id}/epics")

        refute html =~ "data-epic-status=\"proposed\"",
               "an epic is already proposed, so what follows would not be watching one " <>
                 "take shape"

        {:ok, context |> Map.put(:live, live) |> Map.put(:html, html)}
      end

      when_ "the main agent groups stories into an epic and sends it", context do
        # Through the tools the agent uses, not by writing rows. The claim is
        # that the screen I am already looking at changes.
        epic = EpicHelpers.propose(context, "The next thing to build", stories: 2)

        {:ok, Map.put(context, :epic, epic)}
      end

      then_ "the epic appears on the screen I am already looking at", context do
        html = render(context.live)

        assert html =~ "data-epic-status=\"proposed\"",
               "the epics screen did not change when the agent made an epic. Watching it " <>
                 "work is the point — a screen that only tells you afterwards is a report."

        {:ok, Map.put(context, :html, html)}
      end

      then_ "and the control that approves it is on that epic", context do
        assert context.html =~ "data-test=\"approve-epic\"",
               "the epic is proposed and there is nothing on it to approve, so the answer " <>
                 "has to be given somewhere else — which is the two-routes problem this " <>
                 "rule exists to avoid"

        {:ok, context}
      end
    end
  end
end
