defmodule CodeMySpec.McpServers.Tasks.ShowInPanelTest do
  @moduledoc """
  The agent's end of story 967.

  `ScreenState` existed with no caller for a while, which is a shape this
  codebase keeps producing: a handler with no producer reads as working code
  and is inert. The viewport event had it until its hook was written, and
  `agent_progress` has it now. This pins the tool that closes it.

  The refusal is the interesting half. Pointing the panel at a story that is
  not on the project would leave the person looking at "that story is gone"
  where they expected their own work — and that message is *correct* for a
  story deleted after the fact, which is why an id the agent invented has to be
  caught here instead. The agent can fix that one; the panel cannot tell them
  apart.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.UsersFixtures
  import CodeMySpec.ProjectsFixtures
  import CodeMySpec.StoriesFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.ShowInPanel
  alias CodeMySpec.ScreenState

  setup do
    user = user_fixture()
    account = account_with_owner_fixture(user, %{name: "Panel #{System.unique_integer()}"})
    scope = user_scope_fixture(user, account)
    project = project_fixture(scope, %{name: "Panel project"})
    scope = %{scope | active_project_id: project.id, active_project: project}

    story = story_fixture(scope, %{title: "The one the agent picks"})

    %{scope: scope, story: story, frame: %Frame{assigns: %{current_scope: scope}}}
  end

  test "pointing the panel at a story records it as an offer", ctx do
    {:reply, response, _frame} =
      ShowInPanel.execute(%{view: "story", story_id: ctx.story.id}, ctx.frame)

    refute response.isError

    screen = ScreenState.get(ctx.scope)

    assert screen.offered_view == "story"
    assert screen.offered_story_id == ctx.story.id

    # Offered, not applied. Whether it lands is the screen's decision — a phone
    # holds one panel and applying it there evicts what the person was watching.
    # A tool that wrote `dynamic_view` directly would take that decision away
    # from the only place that knows the width.
    refute screen.dynamic_view == "story",
           "the tool applied the change itself, which is how an agent ends up " <>
             "interrupting somebody mid-sentence on a phone"
  end

  test "pointing it at the list needs no story", ctx do
    {:reply, response, _frame} = ShowInPanel.execute(%{view: "stories"}, ctx.frame)

    refute response.isError
    assert ScreenState.get(ctx.scope).offered_view == "stories"
  end

  test "pointing the panel at epics needs no story either", ctx do
    {:reply, response, _frame} = ShowInPanel.execute(%{view: "epics"}, ctx.frame)

    refute response.isError
    assert ScreenState.get(ctx.scope).offered_view == "epics"
  end

  test "a story that is not on this project is refused", ctx do
    {:reply, response, _frame} =
      ShowInPanel.execute(%{view: "story", story_id: 99_999_999}, ctx.frame)

    assert response.isError,
           "the panel was pointed at a story that does not exist here. The person would " <>
             "see it reported as gone, which is the right message for a story deleted " <>
             "after the fact and the wrong one for an id the agent made up."

    refute ScreenState.get(ctx.scope).offered_view,
           "a refused call still changed what the screen is being asked to show"
  end

  test "a view the panel cannot show is refused", ctx do
    {:reply, response, _frame} = ShowInPanel.execute(%{view: "three-amigos"}, ctx.frame)

    assert response.isError
    refute ScreenState.get(ctx.scope).offered_view
  end
end
