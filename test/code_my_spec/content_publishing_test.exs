defmodule CodeMySpec.ContentPublishingTest do
  @moduledoc """
  `publish/1`'s content-bucket precondition (issue b2a784f2).

  `do_publish/2` calls `S3Client.put_object/4` unconditionally, and ExAws
  raises `RuntimeError` on a `nil` bucket rather than returning an error
  tuple — a project whose storage step hasn't finished yet (or was never
  configured) crashed the calling LiveView's gen_server outright, past the
  `{:error, %{message:}}` flash-handling clause entirely.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.ContentPublishing
  alias CodeMySpec.ContentPublishing.Snapshot
  alias CodeMySpec.Repo

  defp put_snapshot(scope, attrs) do
    %Snapshot{}
    |> Snapshot.changeset(
      Map.merge(
        %{
          raw_content: "# Hello",
          processed_content: "<h1>Hello</h1>",
          parse_status: :success,
          metadata: %{"slug" => "hello", "content_type" => "post", "title" => "Hello"}
        },
        Map.new(attrs)
      )
      |> Map.put(:project_id, scope.active_project_id)
    )
    |> Repo.insert!()
  end

  describe "publish/1 — no content bucket configured" do
    setup do
      {:ok, scope: full_scope_fixture(%{content_bucket: nil})}
    end

    test "refuses with a graceful error instead of crashing on a nil bucket", ctx do
      put_snapshot(ctx.scope, %{})

      assert {:error, %{message: message}} = ContentPublishing.publish(ctx.scope)
      assert message =~ "content bucket"
    end

    test "a blank string is treated the same as unset", ctx do
      {:ok, project} =
        CodeMySpec.Projects.update_project(ctx.scope, ctx.scope.active_project, %{
          content_bucket: ""
        })

      scope = %{ctx.scope | active_project: project}
      put_snapshot(scope, %{})

      assert {:error, %{message: message}} = ContentPublishing.publish(scope)
      assert message =~ "content bucket"
    end
  end

  describe "publish/1 — parse errors still take priority over an empty snapshot" do
    test "a missing bucket is reported even with no snapshot rows at all" do
      scope = full_scope_fixture(%{content_bucket: nil})

      assert {:error, %{message: message}} = ContentPublishing.publish(scope)
      assert message =~ "content bucket"
    end
  end
end
