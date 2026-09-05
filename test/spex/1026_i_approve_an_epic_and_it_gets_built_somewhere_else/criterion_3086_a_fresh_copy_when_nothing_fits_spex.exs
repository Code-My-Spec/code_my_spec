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
  import CodeMySpecSpex.WorkingCopyHelpers

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

      given_ "a machine holding this project's repository", context do
        copy = join_working_copy(context, "/tmp/spex_3086_main", "the project's checkout")

        {:ok, Map.put(context, :main, copy.working_copy_id)}
      end

      given_ "no existing working copy suits the epic", context do
        {:ok, _live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/working-copies")

        # "Nothing suits it" is the ordinary state, not an exotic one. A project
        # whose only checkout is its main one has nowhere an epic may go: the
        # main copy holds exactly one agent and it is the project's own, so an
        # epic placed there could never be staffed. John: "the main copy just
        # gets the main agent, and we would create a working copy to do the
        # actual work on."
        carrying =
          ~r/data-test="working-copy"[^>]*data-working-copy-id="([^"]+)"/
          |> Regex.scan(html)
          |> Enum.map(&List.last/1)

        refute html =~ ~s(data-test="epic-working-copy"),
               "a copy is already carrying an epic, so this project has somewhere " <>
                 "suitable and the premise does not hold"

        {:ok, Map.put(context, :before, carrying)}
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
        {:ok, _live, copies} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/working-copies")

        after_ =
          ~r/data-test="working-copy"[^>]*data-working-copy-id="([^"]+)"/
          |> Regex.scan(copies)
          |> Enum.map(&List.last/1)

        assert length(after_) > length(context.before),
               "no checkout was made. A project whose first epic has nowhere to go " <>
                 "cannot start, and the main checkout is not somewhere it may go."

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
