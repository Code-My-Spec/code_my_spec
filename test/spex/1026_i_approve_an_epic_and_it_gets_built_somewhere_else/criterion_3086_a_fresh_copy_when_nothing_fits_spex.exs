defmodule CodeMySpecSpex.Story964.Criterion3086Spex do
  @moduledoc """
  Story 964 — I approve an epic and it gets built somewhere else.
  Criterion 3086 — A fresh copy when nothing fits.

  Rule: The main agent chooses whether an epic goes to a working copy that
  already exists or to a new one.

  The other half of the choice. Criterion 3085 covers reuse; this covers the
  case John named in the same breath — *"or a fresh one at the agent's
  discretion."*

  It is the case that makes the boundary rule usable at all. If an epic can only
  ever land on a copy that already exists, then "come up with a working copy for
  the war epic, keep those three agents through it, then discard it" has no
  first step — the user would have to make the checkout by hand, which is the
  thing story 963 exists to stop them needing to know about.

  ## What this does not assert

  Where the copy is minted, or on which machine. That is the placement question
  and it belongs with whoever builds it. What this fixes is that a copy comes
  into existence because an epic needed one, without the user creating it.

  ## Red on purpose

  `EpicDispatch.destination/1` answers the project's main checkout when it has
  one and `nil` when it does not — and `nil` is dispatched anyway, deliberately:
  "An epic with nowhere to go is still dispatched rather than refused: the
  decision was the user's and it stands." That is the right call for an epic
  that cannot be placed. It is not a substitute for placing it.
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

  spex "The main agent chooses whether an epic goes to a working copy that already exists or to a new one" do
    scenario "A fresh copy when nothing fits" do
      given_ :synced_context_component

      given_ "no existing working copy suits the epic", context do
        {:ok, _live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/working-copies")

        refute html =~ ~s(data-test="working-copy"),
               "the premise is a project with nowhere for the work to go, and this " <>
                 "one already has a checkout"

        {:ok, context}
      end

      when_ "I approve it", context do
        epic = EpicHelpers.propose(context, "The war epic", stories: 1)

        {:ok, live, _html} = live(context.conn, ~p"/app/projects/#{context.project.id}/epics")

        html =
          live
          |> element(~s([data-test=approve-epic][data-epic-id="#{epic}"]))
          |> render_click()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the main agent mints a copy for it", context do
        assert context.html =~ ~s(data-test="epic-working-copy"),
               "the epic was approved and has nowhere to be built. The page reports " <>
                 "that honestly, which is right for an epic that cannot be placed — " <>
                 "but a project whose first epic can never be placed cannot start. " <>
                 "Got: #{String.slice(context.html, 0, 400)}"

        {:ok, context}
      end
    end
  end
end
