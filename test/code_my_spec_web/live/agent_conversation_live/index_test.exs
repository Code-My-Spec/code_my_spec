defmodule CodeMySpecWeb.AgentConversationLive.IndexTest do
  @moduledoc """
  The list of a project's agent sessions.

  The page exists because the cockpit answers "whichever session moved most
  recently" — which reads as *the* session while a project has one agent and
  hides four when it has five. So the tests that matter are: every session is
  here, the newest is first, each row reaches its own transcript, and the name
  can be changed to something a person chose.
  """

  use CodeMySpecTest.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias CodeMySpec.Conversations

  setup [:register_log_in_setup_account]

  setup %{scope: scope, account: account} = context do
    project =
      CodeMySpec.ProjectsFixtures.project_fixture(scope,
        account_id: account.id,
        name: "sessions-project"
      )

    Map.put(context, :project, project)
  end

  defp path(project), do: "/app/projects/#{project.id}/agent-conversations"

  # Move a conversation's last-activity timestamp, without going through the
  # context — every path that writes one stamps "now", and the point here is a
  # row that last moved an hour ago.
  defp stamp(conversation, at) do
    import Ecto.Query

    CodeMySpec.Repo.update_all(
      from(c in CodeMySpec.Conversations.Conversation, where: c.id == ^conversation.id),
      set: [updated_at: at]
    )
  end

  # The rows in render order, by id.
  #
  # This used to compare `:binary.match/2` positions of the two display names in
  # the raw HTML, which answers "where does this string first appear anywhere on
  # the page" — inside an attribute, a script payload, a flash, a title. That is
  # not the list's order, and it agrees with the list's order only by luck.
  #
  # The luck is worth naming: this assertion failed once, inside a promotion's
  # analyzer sweep, and could not be reproduced afterwards — twenty-five
  # consecutive isolated runs, a run on the analyzer's own partition, and the
  # full 724-test web suite on that partition, all green. Whether that failure
  # was this weakness or something real is now a question that cannot be asked
  # of this test again, which is the point: it can only fail for the reason it
  # names.
  defp listed_ids(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("[data-test='agent-conversation']")
    |> Enum.flat_map(&Floki.attribute(&1, "data-conversation-id"))
  end

  defp session(scope, project, external_id) do
    {:ok, conversation} =
      Conversations.find_or_create_session_conversation(
        scope.active_account_id,
        project.id,
        external_id
      )

    conversation
  end

  describe "with nothing recorded" do
    test "says so rather than rendering an empty list", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, path(project))

      assert html =~ "No sessions yet",
             "a bare empty list is indistinguishable from a page that failed to load."
    end
  end

  describe "listing sessions" do
    test "every session is here, not just the one that moved last", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      first = session(scope, project, "pi:/tmp/copy-one")
      second = session(scope, project, "pi:/tmp/copy-two")

      {:ok, _view, html} = live(conn, path(project))

      assert html =~ Conversations.display_name(first)

      assert html =~ Conversations.display_name(second),
             """
             Only one session is listed. This is the failure the page exists to
             fix: the cockpit already answers "the most recent one", and a list
             that agrees with it adds nothing.
             """
    end

    test "newest activity first", %{conn: conn, scope: scope, project: project} do
      # Created first, and the one being worked in. Created *second* and quiet
      # since — so ordering by creation and ordering by activity disagree, which
      # is the only way this test can tell them apart.
      active = session(scope, project, "pi:/tmp/active")
      quiet = session(scope, project, "pi:/tmp/quiet")

      # Stamped rather than slept: `updated_at` is truncated to the second, so
      # two rows made in the same second tie and the order comes out arbitrary.
      quiet_at = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
      stamp(quiet, quiet_at)

      {:ok, _} = Conversations.add_agent_message(active, nil, "assistant", "took a turn")

      {:ok, _view, html} = live(conn, path(project))

      assert listed_ids(html) == [active.id, quiet.id],
             """
             The session that moved most recently is not first. Ordered by
             creation, the list puts a session nobody has touched in an hour
             above the one being worked in right now.
             """
    end

    test "a row opens that session in the cockpit", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      conversation = session(scope, project, "pi:/tmp/openable")

      {:ok, _view, html} = live(conn, path(project))

      assert html =~ "agent-conversation?conversation=#{conversation.id}",
             """
             The row does not name the session it opens. Without the query param
             the link lands on whichever session the cockpit defaults to, which
             is the behaviour this page was built to get away from.
             """
    end

    test "another account's sessions are not listed", %{conn: conn, project: project} do
      other = CodeMySpec.UsersFixtures.full_scope_fixture(%{name: "someone-elses"})
      theirs = session(other, other.active_project, "pi:/tmp/theirs")

      {:ok, _view, html} = live(conn, path(project))

      refute html =~ Conversations.display_name(theirs)
    end
  end

  describe "renaming" do
    test "a name a person chose replaces the generated one", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      conversation = session(scope, project, "pi:/tmp/renameable")
      generated = Conversations.display_name(conversation)

      {:ok, view, _html} = live(conn, path(project))

      html =
        view
        |> element(~s{[data-test="rename-agent-conversation-start"]})
        |> render_click()

      assert html =~ "rename-agent-conversation"

      html =
        view
        |> form(~s{[data-test="rename-agent-conversation"]}, %{"name" => "backend refactor"})
        |> render_submit()

      assert html =~ "backend refactor"

      refute html =~ generated,
             """
             The generated name is still on the page after a rename. The whole
             point of the name being editable is that "amber-kestrel" tells you
             nothing and "backend refactor" does.
             """
    end

    test "a blank name is refused and the session keeps the name it had", %{
      conn: conn,
      scope: scope,
      project: project
    } do
      conversation = session(scope, project, "pi:/tmp/blankable")
      generated = Conversations.display_name(conversation)

      {:ok, view, _html} = live(conn, path(project))

      view
      |> element(~s{[data-test="rename-agent-conversation-start"]})
      |> render_click()

      html =
        view
        |> form(~s{[data-test="rename-agent-conversation"]}, %{"name" => "   "})
        |> render_submit()

      assert html =~ "can&#39;t be blank",
             "a refusal that does not say what was wrong leaves the person retyping the same thing."

      assert Conversations.display_name(
               Conversations.get_agent_conversation_by_id(scope, conversation.id)
             ) == generated
    end
  end
end
