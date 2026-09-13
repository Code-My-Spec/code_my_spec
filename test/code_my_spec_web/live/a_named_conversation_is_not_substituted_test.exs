defmodule CodeMySpecWeb.ANamedConversationIsNotSubstitutedTest do
  @moduledoc """
  The page shows the conversation the URL names, or none — never a different
  one.

  Issue `21325686`. `resolve_conversation/3` fell through to the project's main
  agent whenever the named conversation did not resolve, and the page rendered
  it without a word: the URL named one agent, the transcript and the pause
  control belonged to another, and a missing agent looked exactly like an agent
  that is not working.

  QA hit it twice trying to confirm story 1014's criterion 3293 and reasonably
  concluded the scope was wrong. It is not — `mount_conversation/3` corrects the
  scope to the project in the URL, and has since 2026-08-14. The silent
  substitution was the whole of it, which is why the account-switching workaround
  they found worked: switching accounts made the id resolve, rather than fixing
  what happens when it does not.

  The second half is the same bug one layer up. `:main` was cached with
  `assign_new/3`, and this LiveView survives navigation between projects — so
  "the project's own agent" could be an answer resolved for a different project
  and kept. Only ever visible to somebody who reaches two projects.
  """

  use CodeMySpecTest.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Conversations
  alias CodeMySpec.WorkingCopies

  setup [:register_log_in_setup_account]

  defp a_project(scope, account, name) do
    CodeMySpec.ProjectsFixtures.project_fixture(scope, account_id: account.id, name: name)
  end

  defp a_conversation(scope, project, external_id) do
    {:ok, conversation} =
      Conversations.find_or_create_session_conversation(
        scope.active_account_id,
        project.id,
        external_id
      )

    conversation
  end

  defp cockpit(project, conversation_id),
    do: "/app/projects/#{project.id}/agent-conversation?conversation=#{conversation_id}"

  # The substitution only has something to substitute when the project has a
  # main agent, so a test without one passes whether or not the bug is present.
  # That is exactly what blinding this caught: the first version of these tests
  # asserted nothing, because `ensure/1` answered an error and the fallback
  # produced `nil` either way.
  defp with_a_main_agent(scope, project, said) do
    scope = %{scope | active_project: project, active_project_id: project.id}

    {:ok, copy} =
      WorkingCopies.issue(scope, nil, label: "the main checkout", device: device_fixture(scope))

    {:ok, _} = WorkingCopies.designate_main(scope, copy.id)

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "main",
        status: :running,
        working_copy: "/tmp/main-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        project.id,
        agent.id
      )

    {:ok, _} = Conversations.add_message(conversation, :assistant, said)

    conversation
  end

  test "an id that names nothing at all is not swapped either", %{
    conn: conn,
    scope: scope,
    account: account
  } do
    here = a_project(scope, account, "the-project-in-the-url")

    _main = with_a_main_agent(scope, here, "the main agent of this project speaking")

    {:ok, _view, html} = live(conn, cockpit(here, Ecto.UUID.generate()))

    refute html =~ "the main agent of this project speaking",
           "a conversation id that resolves to nothing rendered the main agent's thread anyway"
  end

  test "and the conversation it does name still renders", %{
    conn: conn,
    scope: scope,
    account: account
  } do
    here = a_project(scope, account, "the-project-in-the-url")

    _main = with_a_main_agent(scope, here, "the main agent of this project speaking")

    mine = a_conversation(scope, here, "agent:here")
    {:ok, _} = Conversations.add_message(mine, :assistant, "a turn from this project")

    {:ok, _view, html} = live(conn, cockpit(here, mine.id))

    assert html =~ "a turn from this project", """
    Refusing to substitute is only right if naming the real one still works.
    Without this the two tests above would pass on a page that shows nothing
    ever.
    """
  end
end
