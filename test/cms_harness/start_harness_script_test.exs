defmodule CmsHarness.StartHarnessScriptTest do
  use ExUnit.Case, async: true

  test "a fresh source checkout installs tools, onboards and starts without a deploy key" do
    dir = CodeMySpec.TempFile.dir("start-harness-script")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    log = Path.join(dir, "commands.log")
    mix = Path.join(dir, "mix")
    git = Path.join(dir, "git")

    File.write!(mix, """
    #!/usr/bin/env bash
    printf 'mix %s [MIX_ENV=%s CMS_SERVER_URL=%s CMS_HARNESS=%s]\n' \"$*\" \"${MIX_ENV:-}\" \"${CMS_SERVER_URL:-}\" \"${CMS_HARNESS:-}\" >> \"$CMS_START_TEST_LOG\"
    """)

    File.write!(git, "#!/usr/bin/env bash\nexit 0\n")
    File.chmod!(mix, 0o755)
    File.chmod!(git, 0o755)

    server = "https://fresh.example.test"
    path = dir <> ":" <> System.get_env("PATH")

    {output, status} =
      System.cmd("bash", ["scripts/start-harness", server],
        cd: File.cwd!(),
        env: [
          {"PATH", path},
          {"MIX_HOME", dir},
          {"CMS_DEPLOY_KEY", ""},
          {"CMS_SERVER_URL", ""},
          {"CMS_START_TEST_LOG", log}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    commands = File.read!(log)
    assert commands =~ "mix local.hex --force"
    assert commands =~ "mix local.rebar --force"
    assert commands =~ "mix deps.get"
    assert commands =~ "mix cms.harness.onboard --server-url #{server}"

    assert commands =~
             "mix run --no-halt [MIX_ENV=harness CMS_SERVER_URL=#{server} CMS_HARNESS=1]"
  end
end
