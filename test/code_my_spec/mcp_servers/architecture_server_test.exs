defmodule CodeMySpec.McpServers.ArchitectureServerTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.McpServers.ArchitectureServer

  describe "ArchitectureServer" do
    test "has correct server info" do
      info = ArchitectureServer.server_info()

      assert info["name"] == "architecture-server"
      assert info["version"] == "1.0.0"
    end

    test "has correct server capabilities" do
      capabilities = ArchitectureServer.server_capabilities()

      assert Map.has_key?(capabilities, "tools")
    end

    test "returns valid child_spec" do
      spec = ArchitectureServer.child_spec([])

      assert spec.id == ArchitectureServer
      assert spec.start == {Anubis.Server.Supervisor, :start_link, [ArchitectureServer, []]}
      assert spec.type == :supervisor
      assert spec.restart == :permanent
    end
  end
end
