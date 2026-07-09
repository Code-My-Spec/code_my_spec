defmodule CodeMySpecWeb.ConversationChannelTest do
  @moduledoc """
  Covers the support widget's "Report a problem" tab: a `submit_feedback` event
  on the deploy-key conversation channel files an issue on the project (source
  "widget"), so reporting and chatting share one widget connection.
  """

  use CodeMySpecTest.DataCase, async: false

  import Phoenix.ChannelTest
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Content.S3Client
  alias CodeMySpec.Issues

  @endpoint CodeMySpecWeb.Endpoint

  # 1x1 png as a data URL, for the screenshot path.
  @png_data_url "data:image/png;base64," <>
                  Base.encode64(<<137, 80, 78, 71, 13, 10, 26, 10>>)

  setup do
    %{scope: full_scope_fixture()}
  end

  defp stub_s3 do
    Req.Test.set_req_test_to_shared(%{})
    prev = Application.get_env(:code_my_spec, S3Client, [])
    Application.put_env(:code_my_spec, S3Client, plug: {Req.Test, S3Client})
    on_exit(fn -> Application.put_env(:code_my_spec, S3Client, prev) end)

    test_pid = self()

    Req.Test.stub(S3Client, fn conn ->
      send(test_pid, {:s3_put, conn.request_path})
      Plug.Conn.send_resp(conn, 200, "")
    end)
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
    assert issue.description == "Clicking Save is a no-op on Safari"
    assert issue.severity == :high
    assert issue.source == "widget"
    assert issue.scope == :app
    assert issue.status == :incoming
    assert issue.project_id == scope.active_project.id
  end

  test "the operator's issue channel is notified of the new widget issue", %{scope: scope} do
    # The operator dashboard / local mirrors subscribe to this topic.
    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "user:#{scope.active_account_id}:issues")

    {:ok, _reply, channel} = join_widget(scope.active_project.id, "eu-2", "user2@example.com")

    ref = push(channel, "submit_feedback", %{"title" => "Typo on pricing", "description" => "It says 'montly'", "severity" => "low"})
    assert_reply ref, :ok, %{id: _}

    assert_receive {:created, %CodeMySpec.Issues.Issue{title: "Typo on pricing"}}
  end

  test "a screenshot is uploaded to S3 and attached to the issue", %{scope: scope} do
    stub_s3()
    {:ok, _reply, channel} = join_widget(scope.active_project.id, "eu-shot", "shot@example.com")

    ref =
      push(channel, "submit_feedback", %{
        "title" => "Layout is broken",
        "description" => "See attached",
        "severity" => "medium",
        "screenshot" => @png_data_url
      })

    assert_reply ref, :ok, %{id: issue_id}
    assert_receive {:s3_put, path}
    assert path =~ "issues/#{scope.active_project.id}/"
    assert path =~ "screenshot.png"

    issue = Issues.get_issue(scope, issue_id)
    assert [%{"type" => "screenshot", "s3_key" => key, "content_type" => "image/png"}] = issue.attachments
    assert String.starts_with?(key, "issues/#{scope.active_project.id}/")
  end

  test "feedback without a screenshot files an issue with no attachments", %{scope: scope} do
    {:ok, _reply, channel} = join_widget(scope.active_project.id, "eu-noshot", "noshot@example.com")

    ref = push(channel, "submit_feedback", %{"title" => "No image", "description" => "x", "severity" => "low"})
    assert_reply ref, :ok, %{id: issue_id}

    assert Issues.get_issue(scope, issue_id).attachments == []
  end

  test "feedback missing a title is rejected and files nothing", %{scope: scope} do
    {:ok, _reply, channel} = join_widget(scope.active_project.id, "eu-3", "user3@example.com")

    ref = push(channel, "submit_feedback", %{"title" => "", "description" => "x", "severity" => "low"})
    assert_reply ref, :error, %{reason: _}

    assert Issues.list_issues(scope) == []
  end
end
