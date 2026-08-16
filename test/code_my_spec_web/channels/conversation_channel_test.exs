defmodule CodeMySpecWeb.ConversationChannelTest do
  @moduledoc """
  Covers the support widget's "Report a problem" tab: a `submit_feedback` event
  on the deploy-key conversation channel files an issue on the project (source
  "widget"), so reporting and chatting share one widget connection. Screenshots
  are uploaded by the browser to a presigned S3 URL handed out by
  `request_screenshot_upload`; only the key travels over the socket.
  """

  # Sync for the same reason as harness_channel_test: the channel runs in its
  # own process and cannot see a connection the test checked out asynchronously.
  # Both channel tests pass alone with `async: true` and fail under concurrency,
  # so a green single-file run is not evidence here.
  use CodeMySpecTest.DataCase, async: false

  import Phoenix.ChannelTest
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Issues

  @endpoint CodeMySpecWeb.Endpoint

  setup do
    %{scope: full_scope_fixture()}
  end

  defp join_widget(project_id, end_user_id, end_user_email) do
    CodeMySpecWeb.WidgetSocket
    |> socket("widget:#{end_user_id}", %{
      project_id: project_id,
      end_user_id: end_user_id,
      end_user_email: end_user_email
    })
    |> subscribe_and_join(CodeMySpecWeb.ConversationChannel, "conversation:#{end_user_id}", %{})
  end

  test "join without an end_user_email is rejected cleanly, not crashed", %{scope: scope} do
    assert {:error, %{reason: "email required"}} =
             join_widget(scope.active_project.id, "eu-no-email", nil)
  end

  test "submit_feedback files an issue on the project, visible to the operator", %{scope: scope} do
    {:ok, _reply, channel} = join_widget(scope.active_project.id, "eu-1", "user@example.com")

    ref =
      push(channel, "submit_feedback", %{
        "title" => "Save button does nothing",
        "description" => "Clicking Save is a no-op on Safari",
        "severity" => "high"
      })

    assert_reply ref, :ok, %{id: issue_id}

    issue = Issues.get_issue(scope, issue_id)
    assert issue.title == "Save button does nothing"
    assert issue.severity == :high
    assert issue.source == "widget"
    assert issue.scope == :app
    assert issue.attachments == []
  end

  test "request_screenshot_upload returns a presigned URL and a project-scoped key", %{scope: scope} do
    {:ok, _reply, channel} = join_widget(scope.active_project.id, "eu-up", "up@example.com")

    ref = push(channel, "request_screenshot_upload", %{"content_type" => "image/png"})
    assert_reply ref, :ok, %{upload_url: url, s3_key: key}

    assert is_binary(url) and url =~ "http"
    assert String.starts_with?(key, "issues/#{scope.active_project.id}/")
    assert String.ends_with?(key, "screenshot.png")
  end

  test "submit_feedback attaches a screenshot the browser already uploaded", %{scope: scope} do
    {:ok, _reply, channel} = join_widget(scope.active_project.id, "eu-shot", "shot@example.com")

    key = "issues/#{scope.active_project.id}/abc-123/screenshot.png"

    ref =
      push(channel, "submit_feedback", %{
        "title" => "Layout is broken",
        "description" => "see screenshot",
        "severity" => "medium",
        "screenshot_key" => key,
        "screenshot_content_type" => "image/png"
      })

    assert_reply ref, :ok, %{id: issue_id}

    assert [%{"type" => "screenshot", "s3_key" => ^key, "content_type" => "image/png"}] =
             Issues.get_issue(scope, issue_id).attachments
  end

  test "a screenshot_key outside the project's prefix is ignored", %{scope: scope} do
    {:ok, _reply, channel} = join_widget(scope.active_project.id, "eu-evil", "evil@example.com")

    ref =
      push(channel, "submit_feedback", %{
        "title" => "Sneaky",
        "description" => "x",
        "severity" => "low",
        "screenshot_key" => "issues/00000000-0000-0000-0000-000000000000/x/screenshot.png"
      })

    assert_reply ref, :ok, %{id: issue_id}
    assert Issues.get_issue(scope, issue_id).attachments == []
  end

  test "the operator's issue channel is notified of the new widget issue", %{scope: scope} do
    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "user:#{scope.active_account_id}:issues")
    {:ok, _reply, channel} = join_widget(scope.active_project.id, "eu-2", "user2@example.com")

    ref = push(channel, "submit_feedback", %{"title" => "Typo on pricing", "description" => "montly", "severity" => "low"})
    assert_reply ref, :ok, %{id: _}

    assert_receive {:created, %CodeMySpec.Issues.Issue{title: "Typo on pricing"}}
  end

  test "request_chat_upload returns a presigned URL and a chat-scoped key", %{scope: scope} do
    {:ok, _reply, channel} = join_widget(scope.active_project.id, "eu-cu", "cu@example.com")

    ref = push(channel, "request_chat_upload", %{"content_type" => "image/png", "filename" => "pic.png"})
    assert_reply ref, :ok, %{upload_url: url, s3_key: key}

    assert url =~ "http"
    assert String.starts_with?(key, "chat/#{scope.active_project.id}/")
    assert String.ends_with?(key, "pic.png")
  end

  test "send_message with an attachment persists it and is pushed back with a URL", %{scope: scope} do
    key = "chat/#{scope.active_project.id}/abc-123/pic.png"
    {:ok, _reply, channel} = join_widget(scope.active_project.id, "eu-att", "att@example.com")

    push(channel, "send_message", %{
      "body" => "here you go",
      "attachments" => [%{"s3_key" => key, "filename" => "pic.png", "content_type" => "image/png", "size" => 10}]
    })

    assert_push "new_message", %{body: "here you go", attachments: [att]}
    assert att.filename == "pic.png"
    assert att.content_type == "image/png"
    assert att.url =~ "http"
  end

  test "an attachment-only message (no text) is accepted", %{scope: scope} do
    key = "chat/#{scope.active_project.id}/def-456/doc.pdf"
    {:ok, _reply, channel} = join_widget(scope.active_project.id, "eu-only", "only@example.com")

    push(channel, "send_message", %{
      "attachments" => [%{"s3_key" => key, "filename" => "doc.pdf", "content_type" => "application/pdf"}]
    })

    assert_push "new_message", %{attachments: [%{filename: "doc.pdf"}]}
  end

  test "an attachment key outside the project prefix is dropped", %{scope: scope} do
    {:ok, _reply, channel} = join_widget(scope.active_project.id, "eu-bad", "bad@example.com")

    push(channel, "send_message", %{
      "body" => "hi",
      "attachments" => [%{"s3_key" => "chat/00000000-0000-0000-0000-000000000000/x/pic.png", "filename" => "pic.png"}]
    })

    assert_push "new_message", %{body: "hi", attachments: []}
  end

  test "feedback missing a title is rejected and files nothing", %{scope: scope} do
    {:ok, _reply, channel} = join_widget(scope.active_project.id, "eu-3", "user3@example.com")

    ref = push(channel, "submit_feedback", %{"title" => "", "description" => "x", "severity" => "low"})
    assert_reply ref, :error, %{reason: _}

    assert Issues.list_issues(scope) == []
  end

  describe "criterion 8055 — a visitor mid-conversation notices no expiry" do
    # Sam's call was that the socket re-authenticates in place rather than
    # dropping and reconnecting. A reconnect is noticed even when it is fast:
    # the channel rejoins from scratch and anything in flight is lost.
    test "a fresh socket token is swapped in on the open channel", %{scope: scope} do
      {:ok, _reply, channel} = join_widget(scope.active_project.id, "eu-reauth", "u@example.com")

      {token, _ttl} = CodeMySpec.AppTokens.issue_socket_token(scope.active_project)

      ref = push(channel, "reauth", %{"socket_token" => token})
      assert_reply ref, :ok, %{status: "ok"}

      # Still the same channel, still able to talk — the point of re-auth in
      # place rather than a reconnect.
      ref = push(channel, "send_message", %{"body" => "still here"})
      assert_reply ref, :ok, _
    end

    test "a token naming another project is refused and leaves the session alone", %{scope: scope} do
      {:ok, _reply, channel} = join_widget(scope.active_project.id, "eu-other", "u2@example.com")

      other = CodeMySpec.ProjectsFixtures.project_fixture(scope, %{name: "other project"})
      {token, _ttl} = CodeMySpec.AppTokens.issue_socket_token(other)

      ref = push(channel, "reauth", %{"socket_token" => token})
      assert_reply ref, :error, %{reason: "project_mismatch"}

      ref = push(channel, "send_message", %{"body" => "unaffected"})
      assert_reply ref, :ok, _
    end

    test "a garbage token is refused with a reason the widget can act on", %{scope: scope} do
      {:ok, _reply, channel} = join_widget(scope.active_project.id, "eu-bad", "u3@example.com")

      ref = push(channel, "reauth", %{"socket_token" => "nonsense"})
      assert_reply ref, :error, %{reason: "invalid"}

      ref = push(channel, "reauth", %{})
      assert_reply ref, :error, %{reason: "missing_socket_token"}
    end
  end
end
