defmodule CodeMySpec.Workspaces.Runner.DockerDevBoxTest do
  @moduledoc """
  Story 1140: Docker is a dev box provider, and a Docker that is not there is
  said so rather than reported as a failed `docker run`.
  """
  use ExUnit.Case, async: false

  alias CodeMySpec.Workspaces.Runner
  alias CodeMySpec.Workspaces.Runner.Docker

  test "Docker is listed as a dev box provider, a local kind of machine" do
    assert Runner.dev_box("docker") == Docker
    assert Docker.label() == "Docker"
    assert Docker.kind() == :local
  end

  test "its instructions say the token is a file, not an environment variable" do
    [section] = Docker.instructions(%{token: "cbt_x", server_url: "http://x"})

    assert section.body =~ "read-only file"
    refute section.body =~ "cbt_x"
  end

  test "with no docker on the PATH, starting is `docker_unreachable`" do
    previous = System.get_env("PATH")
    System.put_env("PATH", "/nonexistent")
    on_exit(fn -> System.put_env("PATH", previous) end)

    assert {:error, :docker_unreachable} = Docker.start("devbox-test", "devbox", 4999, [])
  end
end
