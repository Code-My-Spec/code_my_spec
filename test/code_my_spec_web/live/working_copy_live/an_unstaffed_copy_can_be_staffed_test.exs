defmodule CodeMySpecWeb.WorkingCopyLive.AnUnstaffedCopyCanBeStaffedTest do
  @moduledoc """
  A copy with no agents has a way to get some.

  Staffing had no button. It happened as a side effect of minting a copy
  (`WorkingCopies.mint/2`) or of dispatching an epic onto one
  (`EpicDispatch`) — so an existing, onboarded, unstaffed copy, which is an
  ordinary state, had no route at all.

  The only control on the page was "Put to work", which flips continuous mode on
  *running* agents and answers "Nothing is running on this copy to put to work"
  when there are none. The single action needed agents to already exist, and the
  empty state said "Nothing is running on this copy." and stopped there.

  John, looking at a copy with 45 stopped agents on it: "I know it's onboarded
  properly, it has no agents. How do I get my agents?"
  """
  use CodeMySpecTest.ConnCase, async: false

  import CodeMySpecSpex.WorkingCopyHelpers
  import Phoenix.LiveViewTest

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpec.Agents.AgentsRepository
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  defp show(context, copy) do
    {:ok, live, _html} =
      live(
        context.conn,
        "/app/projects/#{context.scope.active_project_id}/working-copies/#{copy.working_copy_id}"
      )

    live
  end

  # A copy that has had agents and has none now — every row `:stopped`. This is
  # the state that looked unrecoverable: the list is empty, so the toggle is
  # hidden, and the toggle was the only control.
  defp copy_with_only_stopped_agents(context, root) do
    copy = join_working_copy(context, root, "a copy whose agents all stopped")

    for role <- ~w(product coding qa) do
      {:ok, _} =
        AgentsRepository.create_agent(context.scope, %{
          engine: :alloy,
          provider: "zai",
          working_copy: root,
          role: role,
          working_copy_id: copy.working_copy_id,
          project_id: context.scope.active_project_id,
          account_id: context.scope.active_account_id,
          status: :stopped
        })
    end

    copy
  end

  test "an empty copy offers the action", %{conn: _conn} = context do
    copy = join_working_copy(context, "/tmp/unstaffed", "an unstaffed copy")

    html = context |> show(copy) |> render()

    assert html =~ ~s(data-test="staff-copy"),
           "a copy with no agents had no way to get any"
  end

  test "a copy whose agents all stopped offers it too", context do
    copy = copy_with_only_stopped_agents(context, "/tmp/all-stopped")

    html = context |> show(copy) |> render()

    assert html =~ ~s(data-test="staff-copy"),
           """
           Every agent on this copy is stopped, so nothing is live and the page
           shows no roster. That is the state John hit, and it read as
           unrecoverable.
           """
  end

  # The empty state used to say "Nothing is running on this copy." and stop
  # there, which is the sentence that sends somebody looking for a control that
  # does not exist.
  test "the empty state says what to do about it", context do
    copy = join_working_copy(context, "/tmp/says-what", "an unstaffed copy")

    html = context |> show(copy) |> render()

    assert html =~ "Staff it"
    assert html =~ "product, coding and QA"
  end

  # Rendering a button is not the feature. This presses it and asserts the page
  # says what happened — which is the half that would still be missing if the
  # handler were wired to nothing.
  test "pressing it reports what happened", context do
    copy = join_working_copy(context, "/tmp/press-it", "an unstaffed copy")

    live = show(copy_context(context), copy)
    live |> element(~s([data-test="staff-copy"])) |> render_click()

    html = render(live)

    assert html =~ "agent" or html =~ "Could not staff",
           """
           The button was pressed and the page said nothing. Whether staffing
           succeeds here depends on the transport this environment has; what must
           not happen is silence, because that is indistinguishable from a
           control wired to nothing.
           """
  end

  # Every failure is named, and none of them arrives as a raw tuple.
  #
  # This is the shape of what John hit: he pressed the button on the project's
  # main checkout, got a product agent, and then
  # `coding - {:main_copy_occupied, "/Users/..."}; qa - {:main_copy_occupied, ...}`
  # — an inspect of an internal tuple, readable only if you already knew the
  # atom was a reason and the string a path.
  #
  # The main-copy refusal itself is not reachable from here: `start_agent/2`
  # checks the transport before that guard, so in this environment every role
  # fails `:not_connected` first. What this pins is the property that covers it
  # — a failure is reported by role, in a sentence, and never as a tuple.
  test "failures are named without printing a tuple", context do
    copy = join_working_copy(context, "/tmp/reports-clearly", "an unstaffed copy")

    live = show(context, copy)
    live |> element(~s([data-test="staff-copy"])) |> render_click()

    html = render(live)

    assert html =~ "Could not staff this copy" or html =~ "Started",
           "the button was pressed and the page said nothing"

    refute html =~ "{:main_copy_occupied",
           "an internal tuple was printed at somebody"
  end

  # Idempotence is what lets the button be safe to press twice — and it is the
  # reason it can be shown on a partly-staffed copy rather than only an empty
  # one. `ensure_copy_agents/2` skips a role that is already live.
  test "a fully staffed copy does not offer it", context do
    copy = join_working_copy(context, "/tmp/fully-staffed", "a staffed copy")

    for role <- ~w(product coding qa) do
      {:ok, _} =
        AgentsRepository.create_agent(context.scope, %{
          engine: :alloy,
          provider: "zai",
          working_copy: root_of(copy),
          role: role,
          working_copy_id: copy.working_copy_id,
          project_id: context.scope.active_project_id,
          account_id: context.scope.active_account_id,
          status: :starting
        })
    end

    html = context |> show(copy) |> render()

    refute html =~ ~s(data-test="staff-copy"),
           "every role is live; offering to staff it again is an action with nothing to do"
  end

  defp root_of(_copy), do: "/tmp/fully-staffed"

  # `show/2` takes the context; naming the pass-through keeps the two click
  # tests reading as "open the page, press the button, read the page".
  defp copy_context(context), do: context
end
