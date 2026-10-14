defmodule CmsHarness.Setup.ConnectionTest do
  use ExUnit.Case, async: true

  alias CmsHarness.Setup.Connection

  test "an unconfirmed connection is timestamped as pending rather than failed" do
    root = Path.join(System.tmp_dir!(), "unconnected-#{System.unique_integer([:positive])}")
    result = Connection.observe(root, 0)
    assert result.connected == false
    assert result.connection_state == "pending"
    assert {:ok, _, _} = DateTime.from_iso8601(result.observed_at)
  end

  test "a checkout belonging to another server is refused without changing its files" do
    root = Path.join(System.tmp_dir!(), "setup-connection-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(
      Path.join(root, "mix.exs"),
      "defmodule Selected.MixProject do\n  use Mix.Project\nend\n"
    )

    config_path = Path.join(root, ".cms_harness.json")

    original =
      Jason.encode!(%{
        working_copy_id: "existing-copy",
        project_id: "existing-project",
        server_url: "https://another-server.invalid",
        root: root,
        custom: "preserve"
      })

    File.write!(config_path, original)

    assert {:error, {:server_identity_conflict, "https://another-server.invalid"}} =
             Connection.connect(root, %{
               project_id: "existing-project",
               working_copy_id: "existing-copy",
               app: "selected"
             })

    assert File.read!(config_path) == original
    refute File.exists?(Path.join(root, ".claude/settings.local.json"))
  end
end
