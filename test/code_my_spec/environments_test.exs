defmodule CodeMySpec.EnvironmentsTest do
  use ExUnit.Case
  import CodeMySpec.Support.CLIRecorder

  # nil cwd: these commands are deliberately ambient (`echo`, `pwd`) — the
  # point is the recorder, not the working directory. Local.cmd/4 leaves :cd
  # unset when the environment has no cwd, so behaviour matches what this test
  # asserted when it passed a bare `:local` type atom.
  @env %CodeMySpec.Environments.Environment{type: :local, cwd: nil}

  test "cmd with CLI recorder using cassette" do
    use_cassette "test_multiple_commands" do
      # First command executes and records
      assert {output1, 0} = CodeMySpec.Environments.cmd(@env, "echo", ["hello world"], [])
      assert String.trim(output1) == "hello world"

      # Second different command executes and records
      assert {output2, 0} = CodeMySpec.Environments.cmd(@env, "echo", ["goodbye world"], [])
      assert String.trim(output2) == "goodbye world"

      # Third command executes and records
      assert {output3, 0} = CodeMySpec.Environments.cmd(@env, "pwd", [], [])
      assert String.contains?(output3, "/")

      # Replay all commands from the same fixture
      assert {replay1, 0} = CodeMySpec.Environments.cmd(@env, "echo", ["hello world"], [])
      assert String.trim(replay1) == "hello world"

      assert {replay2, 0} = CodeMySpec.Environments.cmd(@env, "echo", ["goodbye world"], [])
      assert String.trim(replay2) == "goodbye world"

      assert {replay3, 0} = CodeMySpec.Environments.cmd(@env, "pwd", [], [])
      assert String.contains?(replay3, "/")
    end
  end
end
