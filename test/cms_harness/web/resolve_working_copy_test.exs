defmodule CmsHarness.Web.ResolveWorkingCopyTest do
  use ExUnit.Case, async: true

  import CmsHarnessTest.Projects

  alias CmsHarness.Web.ResolveWorkingCopy

  test "the first addressed hook resolves its matching local working copy" do
    project = project_dir()

    conn = conn_for(project.working_copy_id, project.root)

    assert {:ok, root} = ResolveWorkingCopy.resolve(conn)
    assert root == project.root
  end

  test "an addressed id does not adopt a different local working copy" do
    project = project_dir()

    conn = conn_for(Ecto.UUID.generate(), project.root)

    refute ResolveWorkingCopy.resolve(conn) == {:ok, project.root}
  end

  defp conn_for(harness_id, root) do
    %Plug.Conn{} = conn = Plug.Test.conn(:post, "/", "")
    %{conn | params: %{"harness_id" => harness_id, "cwd" => root}}
  end
end
