defmodule CodeMySpec.EnvironmentsTest do
  # Sync, and not incidentally: the `clean_otp_env` tests below replace PATH
  # with `/usr/bin:/usr/local/bin` for the duration of a test.
  #
  # PATH belongs to the node, and `System.cmd/3` resolves binaries through it.
  # `sops` and `age-keygen` live in `/opt/homebrew/bin`, which that value drops
  # — so anything shelling out while the window is open stops finding them.
  # `Provisioning.Sops` alone is reached by five async test files, and what they
  # would report is a non-zero exit from a tool that is installed and working.
  #
  # `clean_otp_env/0` reads the ambient environment by design — it exists to
  # scrub what a Burrito release exports — so testing it means mutating the
  # real thing. Sync is the isolation, which is why it is now said out loud:
  # this file carried no `async:` at all, and a file that is safe only by
  # omission is one flip away from a nondeterministic failure somewhere else.
  use ExUnit.Case, async: false

  import CodeMySpec.Support.CLIRecorder

  alias CodeMySpecTest.EnvRestore

  # These commands are deliberately ambient (`echo`, `pwd`) — the point is the
  # recorder, not the working directory. Said explicitly rather than by leaving
  # cwd nil: `Local.cmd/4` used to fill a missing cwd from the OS process, which
  # meant an environment that did not know its project silently analysed
  # whichever one the caller was sitting in (c8264c1f). It now refuses, so a
  # caller that really wants the ambient directory names it.
  @env %CodeMySpec.Environments.Environment{type: :local, cwd: File.cwd!()}

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

  describe "clean_otp_env/0 PATH sanitising" do
    # Clearing ROOTDIR was never enough. The release's own erts-*/bin sits on
    # PATH — first, under the Windows MSI — so the child resolved `erl` to OUR
    # erl no matter what we unset, and that erl looked for <root>/bin/start.boot
    # (a path no release has) and died with "cannot get bootfile" before running.
    setup do
      prev_root = System.get_env("RELEASE_ROOT")
      prev_path = System.get_env("PATH")

      on_exit(fn ->
        EnvRestore.restore("RELEASE_ROOT", prev_root)
        EnvRestore.restore("PATH", prev_path)
      end)

      :ok
    end

    defp path_entry(env), do: Enum.find_value(env, fn {k, v} -> k == "PATH" && v end)

    test "drops PATH entries inside the release root, keeps the rest" do
      System.put_env("RELEASE_ROOT", "/opt/cms/libexec")
      System.put_env("PATH", "/opt/cms/libexec/erts-15.2/bin:/usr/bin:/opt/cms/libexec/bin:/usr/local/bin")

      assert path_entry(CodeMySpec.Environments.clean_otp_env()) == "/usr/bin:/usr/local/bin"
    end

    test "leaves PATH untouched when not running from a release" do
      System.delete_env("RELEASE_ROOT")
      System.put_env("PATH", "/usr/bin:/usr/local/bin")

      refute path_entry(CodeMySpec.Environments.clean_otp_env())
    end

    test "leaves PATH alone rather than emptying it" do
      System.put_env("RELEASE_ROOT", "/opt/cms/libexec")
      System.put_env("PATH", "/opt/cms/libexec/erts-15.2/bin:/opt/cms/libexec/bin")

      refute path_entry(CodeMySpec.Environments.clean_otp_env())
    end

    test "still clears the release env vars" do
      env = CodeMySpec.Environments.clean_otp_env()
      assert {"ROOTDIR", nil} in env
      assert {"ERTS_BIN", nil} in env
      assert {"ELIXIR_VERSION", nil} in env
    end
  end
end
