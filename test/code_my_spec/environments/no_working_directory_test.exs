defmodule CodeMySpec.Environments.NoWorkingDirectoryTest do
  @moduledoc """
  An environment with no working directory must not mean "the server's".

  This is the bug that produced the others. A project with no `local_path` —
  the normal case on the light harness — resolved to
  `%Environment{type: :local, cwd: nil}`: not nil, so every `is_nil/1` guard
  waved it through, and then a relative path resolved against whatever
  directory the OS process was in. On a server that is its own checkout.

  Drill 7 wrote eight `e2e_todo` spec stubs into the code_my_spec repository
  this way, and the container's spec directory stayed empty — so no component
  had dependency edges, every component read as an orphan, and
  `architecture_designed` could not pass while the agent had done everything
  right.
  """

  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.Environments.{Cli, Local}
  alias CodeMySpec.Environments.Environment

  describe "a directoryless environment, if one is ever built again" do
    setup do
      # The adapters directly: `Environments.read_file/2` dispatches through
      # `Application.get_env(:code_my_spec, :environment, ...)`, which in the
      # test environment is the in-memory double, so going through the front
      # door would never reach this code.
      %{env: %Environment{type: :local, cwd: nil}}
    end

    test "refuses to write a relative path instead of resolving it against the server", %{
      env: env
    } do
      assert_raise ArgumentError, ~r/no working directory/, fn ->
        Local.write_file(env, ".code_my_spec/spec/thing.spec.md", "contents")
      end
    end

    test "refuses to read one too", %{env: env} do
      assert_raise ArgumentError, ~r/no working directory/, fn ->
        Local.read_file(env, "mix.exs")
      end
    end

    test "the cli adapter refuses the same way", %{env: env} do
      assert_raise ArgumentError, ~r/no working directory/, fn ->
        Cli.read_file(%{env | type: :cli}, "mix.exs")
      end
    end

    test "an absolute path is unambiguous and still allowed", %{env: env} do
      # Nothing to resolve, so nothing to get wrong.
      assert {:error, :enoent} = Local.read_file(env, "/definitely/not/here/mix.exs")
    end
  end
end
