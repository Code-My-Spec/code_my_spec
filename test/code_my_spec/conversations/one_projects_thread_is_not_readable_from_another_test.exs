defmodule CodeMySpec.Conversations.OneProjectsThreadIsNotReadableFromAnotherTest do
  @moduledoc """
  `get_agent_conversation_by_id/2` is scoped to the project as well as the
  account.

  Filed from a source reading as `4a470cc3` and confirmed live as `7dbf9709`:
  two projects in one account, the same conversation id under each URL, and the
  second rendered the first project's full agent transcript — messages, restart
  notices and a `bash mix deps.get` tool call — under the second project's
  chrome. The page said one project; the content was another's private agent
  activity.

  ## Why this is a context test rather than a page test

  I wrote it against the LiveView twice and could not make it fail with the
  scope check removed, both times for reasons I did not establish — so it would
  have been a green test proving nothing, which is worse than none. The
  behaviour under test is one `where` clause in one function, and that is what
  this asserts.

  The page-level guarantee has its own test in
  `ANamedConversationIsNotSubstitutedTest`, covering the other half: a named
  conversation that does not resolve renders as nothing rather than as somebody
  else's thread.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Conversations

  # A copy of its own per project. Reusing one across projects is refused as
  # `:cross_project_working_copy`, which is the tenancy rule this test is about
  # holding somewhere else.
  defp an_agent_conversation(scope, project) do
    scope = %{scope | active_project: project, active_project_id: project.id}

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: CodeMySpec.DevicesFixtures.device_fixture(scope)
      )

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        working_copy: "/tmp/thread-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        project.id,
        agent.id
      )

    conversation
  end

  setup do
    scope = full_scope_fixture()

    elsewhere =
      CodeMySpec.ProjectsFixtures.project_fixture(scope,
        account_id: scope.active_account_id,
        name: "somewhere-else"
      )

    %{scope: scope, elsewhere: elsewhere}
  end

  test "a thread from another project in the same account does not resolve", %{
    scope: scope,
    elsewhere: elsewhere
  } do
    theirs = an_agent_conversation(scope, elsewhere)

    refute Conversations.get_agent_conversation_by_id(scope, theirs.id), """
    One project's agent thread resolved under another project's scope. Both are
    in one account, which is the whole precondition — the check was on the
    account alone, one axis short of what its callers assume, and the show page
    renders whatever this returns under the URL's chrome (7dbf9709).
    """
  end

  test "and the project's own thread still does", %{scope: scope} do
    {:ok, here} = CodeMySpec.Projects.get_project(scope, scope.active_project_id)
    mine = an_agent_conversation(scope, here)

    assert Conversations.get_agent_conversation_by_id(scope, mine.id), """
    Refusing another project's thread is only right if this project's still
    resolves. Without this the test above would pass on a function that returns
    nil for everything.
    """
  end
end
