defmodule CodeMySpecSpex.Story964.Criterion3092Spex do
  @moduledoc """
  Story 964 — I approve an epic and it gets built somewhere else.
  Criterion 3092 — A new epic gets a new copy, not the old one's agents.

  Rule: A working copy is the boundary of the work: discarding it ends its
  agents and its conversation.

  The other side of discarding. John, 2026-09-04: *"I can discard the working
  copy and then come up with another one — that's how I need to control these
  boundaries."*

  Discarding only buys a boundary if what comes next is genuinely separate. A
  fresh copy that inherited the last epic's conversation would give the new
  agents the old work's context, which is the thing the discard was for.

  ## Where this sits against reuse

  Criterion 2936 says a copy *may* hold a second epic, and 3090 says the same
  three agents take it. This is not in tension with either: both are about a
  copy the user has kept. This is about one they threw away. Keeping a copy and
  discarding it are two different decisions, and the point of the boundary is
  that the user makes it rather than the system inferring it from how much work
  is outstanding.

  ## Red on purpose

  Nothing mints a copy for an epic — `EpicDispatch.destination/1` answers the
  project's main checkout or `nil`, and never creates one (criterion 3086).
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.EpicHelpers
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project


  # The copy the epic actually landed on. Not `context.copy_id` — that is the
  # project's main checkout, and an epic never goes there: the main copy holds
  # one agent and it is the project's own, so an epic gets one made for it.
  defp epic_copy(context) do
    {:ok, _live, epics} = live(context.conn, ~p"/app/projects/#{context.project.id}/epics")

    [_, id] =
      Regex.run(~r/data-test="epic-working-copy"[^>]*data-working-copy-id="([^"]+)"/, epics)

    id
  end

  # Through the confirm dialog, which is how a person discards a copy — the
  # button opens it and the dialog's own control is what acts.
  defp discard(context, copy_id) do
    {:ok, live, _html} =
      live(context.conn, ~p"/app/projects/#{context.project.id}/working-copies")

    live
    |> element("#offboard-#{copy_id} [data-role='confirm-confirm']")
    |> render_click()
  end

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A working copy is the boundary of the work" do
    scenario "A new epic gets a new copy, not the old one's agents" do
      given_ :synced_context_component

      given_ "a connected provider for the agents to run on", context do
        {:ok, _integration} = Fixtures.connect_provider(context.scope, :openai)

        {:ok, context}
      end

      given_ "I have discarded the working copy for the last epic", context do
        context = EpicHelpers.dispatch_one(context, "The last epic", stories: 1)

        copy_id = epic_copy(context)
        discard(context, copy_id)

        {:ok, Map.put(context, :discarded, copy_id)}
      end

      when_ "I start the next one", context do
        context = EpicHelpers.dispatch_one(Map.delete(context, :copy_id), "The next epic", stories: 1)

        {:ok, _live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/working-copies")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "it gets its own copy with its own three agents", context do
        refute context.html =~ context.discarded,
               "the new epic went to the copy I threw away. Discarding is how I say " <>
                 "that work is over, and it did not take."

        for role <- ~w(product coding qa) do
          assert context.html =~ ~s(data-role="#{role}"),
                 "the new copy came up without a #{role} agent"
        end

        {:ok, context}
      end

      then_ "and that copy's conversation starts clean", context do
        refute context.html =~ "The last epic",
               "the new copy is carrying the discarded epic's context. A fresh copy " <>
                 "that inherits the last one's conversation gives the new agents the " <>
                 "old work to reason about, which is the thing the discard was for."

        {:ok, context}
      end
    end
  end
end
