defmodule CodeMySpecWeb.ConversationChannelTest do
  @moduledoc """
  Covers the support widget's "Report a problem" tab: a `submit_feedback` event
  on the deploy-key conversation channel files an issue on the project (source
  "widget"), so reporting and chatting share one widget connection. Screenshots
  are uploaded by the browser to a presigned S3 URL handed out by
  `request_screenshot_upload`; only the key travels over the socket.
  """

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
end
