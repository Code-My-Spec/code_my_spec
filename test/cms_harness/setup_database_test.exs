defmodule CmsHarness.Setup.DatabaseTest do
  use ExUnit.Case, async: true

  alias CmsHarness.Setup.{Database, Platform}

  test "existing local access is a no-op with recorded evidence" do
    assert {:ok, %{created?: false, username: "jane", commands: [_, probe]}} =
             prepare([{"id", ["-un"], "jane\n", 0}, {"psql", :any, "1\n", 0}])

    assert "--host=/var/run/postgresql" in probe.args
    assert "--port=5432" in probe.args
    assert "--username=jane" in probe.args
    assert "--no-password" in probe.args
  end

  test "Linux root creates only a verified missing local role then verifies access" do
    script = [
      {"id", ["-un"], "root\n", 0},
      {"psql", :any, ~s(role "root" does not exist), 2},
      {"id", ["-u"], "0\n", 0},
      {"runuser", :any, "", 0},
      {"runuser", :any, "", 0},
      {"psql", :any, "1\n", 0}
    ]

    assert {:ok, %{created?: true, commands: commands}} = prepare(script)
    lookup = Enum.at(commands, 3)
    assert ["-u", "postgres", "--", "psql" | _] = lookup.args
    assert "SELECT 1 FROM pg_roles WHERE rolname = 'root'" in lookup.args
    creation = Enum.at(commands, 4)

    assert creation.args == [
             "-u",
             "postgres",
             "--",
             "createuser",
             "--no-password",
             "--host=/var/run/postgresql",
             "--port=5432",
             "--username=postgres",
             "--login",
             "--createdb",
             "--",
             "root"
           ]
  end

  test "existing inaccessible role is not modified" do
    assert {:error, %{commands: commands, error: error}} =
             prepare([
               {"id", ["-un"], "root", 0},
               {"psql", :any, "authentication failed", 2},
               {"id", ["-u"], "0", 0},
               {"runuser", :any, "1\n", 0}
             ])

    assert length(commands) == 4
    assert error =~ "existing roles, passwords and authentication settings"
  end

  test "non-root failure is actionable and does not try privilege escalation" do
    assert {:error, %{commands: commands, error: error}} =
             prepare([
               {"id", ["-un"], "jane", 0},
               {"psql", :any, "role missing", 2},
               {"id", ["-u"], "1000", 0}
             ])

    assert Enum.map(commands, & &1.command) == ["id", "psql", "id"]
    assert error =~ "administrator"
  end

  test "failed administrative connection cannot trigger role creation" do
    assert {:error, %{commands: commands}} =
             prepare([
               {"id", ["-un"], "root", 0},
               {"psql", :any, "connection refused", 2},
               {"id", ["-u"], "0", 0},
               {"runuser", :any, "connection refused", 2}
             ])

    assert length(commands) == 4
  end

  test "creation failure is recorded without claiming success" do
    assert {:error, %{commands: commands, error: error}} =
             prepare([
               {"id", ["-un"], "root", 0},
               {"psql", :any, "role missing", 2},
               {"id", ["-u"], "0", 0},
               {"runuser", :any, "", 0},
               {"runuser", :any, "permission denied", 1}
             ])

    assert length(commands) == 5
    assert error =~ "Could not create"
  end

  test "successful creation still requires a successful access probe" do
    assert {:error, %{commands: commands}} =
             prepare([
               {"id", ["-un"], "root", 0},
               {"psql", :any, "role missing", 2},
               {"id", ["-u"], "0", 0},
               {"runuser", :any, "", 0},
               {"runuser", :any, "", 0},
               {"psql", :any, "authentication failed", 2}
             ])

    assert length(commands) == 6
  end

  test "macOS verifies its local socket without trying Linux administrative commands" do
    assert {:ok, %{commands: [_, probe]}} =
             prepare(
               [
                 {"id", ["-un"], "jane", 0},
                 {"psql", :any, "1\n", 0}
               ],
               platform: %Platform{os: :darwin, arch: :aarch64}
             )

    assert "--host=/tmp" in probe.args
  end

  test "unsupported platforms and network destinations never execute commands" do
    assert {:error, %{commands: []}} =
             prepare([], platform: %Platform{os: :windows, arch: :x86_64})

    assert {:error, %{commands: []}} = prepare([], socket_directory: "db.example.com")
  end

  test "untrusted or unavailable OS identity does not reach SQL" do
    assert {:error, %{commands: [_]}} =
             prepare([{"id", ["-un"], "a'; DROP ROLE postgres; --", 0}])

    assert {:error, %{commands: [_]}} = prepare([{"id", ["-un"], "", 1}])
  end

  defp prepare(script, opts \\ []) do
    key = make_ref()
    Process.put(key, script)

    runner = fn _cwd, command, args ->
      [{expected_command, expected_args, output, status} | rest] = Process.get(key)
      assert command == expected_command
      if expected_args != :any, do: assert(args == expected_args)
      Process.put(key, rest)

      %{
        command: command,
        args: args,
        output: output,
        exit_status: status,
        error: if(status == 0, do: nil, else: "command failed")
      }
    end

    result =
      Database.prepare(
        "/tmp",
        Keyword.merge(
          [
            platform: %Platform{os: :linux, arch: :aarch64},
            runner: runner,
            runuser_command: "runuser"
          ],
          opts
        )
      )

    assert Process.delete(key) == []
    result
  end
end
