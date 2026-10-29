defmodule CmsHarness.SopsKeySocketScopeTest do
  use ExUnit.Case, async: false

  test "a deep HOME still has a bindable per-user socket path" do
    previous = System.get_env("CMS_STATE_DIR")
    deep_state = Path.join(System.tmp_dir!(), String.duplicate("deep-home-", 17))
    System.put_env("CMS_STATE_DIR", deep_state)

    on_exit(fn ->
      if previous,
        do: System.put_env("CMS_STATE_DIR", previous),
        else: System.delete_env("CMS_STATE_DIR")
    end)

    assert byte_size(deep_state) > 150
    path = Path.join(CmsHarness.SopsKeySocket.dir(), "key.sock")
    assert byte_size(path) < 100
    assert String.starts_with?(path, "/tmp/cms-sops-")
    assert {:ok, listener} = CmsHarness.SopsKeySocket.start_link(path: path)
    assert File.exists?(path)
    GenServer.stop(listener)
  end

  test "ExUnit binds a socket private to its own BEAM" do
    expected =
      Path.join([System.tmp_dir!(), "cms-sops-key-sockets", "key-#{System.pid()}.sock"])

    assert System.get_env("CMS_SOPS_KEY_SOCKET_PATH") == expected
    assert CmsHarness.SopsKeySocket.path() == expected

    assert elem(:os.type(), 0) == :win32 or File.exists?(expected)
  end
end
