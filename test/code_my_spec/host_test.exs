defmodule CodeMySpec.HostTest do
  @moduledoc """
  `CodeMySpec.Host` runs the host scripts through whatever environment the
  scope carries — a container in dev, a Hetzner box in prod — and never
  branches on which. These tests pin the contract at the seam: what command
  gets run, with what arguments and environment, and how the two outcomes are
  reported.

  The scripts themselves are exercised for real by `priv/host/drill.sh`
  (isolation checks, including the breaches) and by the full-boot image; there
  is no value in re-deriving bash behaviour in ExUnit.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Host
  alias CodeMySpec.Users.Scope

  # A scope with a placeholder environment plus a recording runner injected
  # through the `:cmd` seam. Enough to assert what command Host builds without
  # standing up a container.
  defp recording_scope(result) do
    test_pid = self()

    runner = fn _env, command, args, opts ->
      send(test_pid, {:cmd, command, args, opts})
      result
    end

    env = %CodeMySpec.Environments.Environment{type: :local, cwd: "/host", ref: %{}}
    {%Scope{environment: env, active_project_id: "p1"}, runner}
  end

  describe "provision_app/3" do
    test "refuses without an admin age key, before running anything" do
      {scope, runner} = recording_scope({"", 0})

      assert {:error, message} = Host.provision_app(scope, %{name: "app1", port: 4001}, cmd: runner)
      assert message =~ "admin"

      # The refusal is the point: a default admin key would silently produce a
      # box whose secrets nobody can read once the box is gone.
      refute_received {:cmd, _, _, _}
    end

    test "runs provision_app.sh with the app, port and admin key" do
      {scope, runner} = recording_scope({"done", 0})

      assert {:ok, "done"} =
               Host.provision_app(scope, %{name: "app1", port: 4001},
                 admin_age_pubkey: "age1admin",
                 cmd: runner
               )

      assert_received {:cmd, command, args, opts}
      assert command =~ "provision_app.sh"
      assert args == ["app1", "4001"]
      assert opts[:env] == [{"ADMIN_AGE_PUBKEY", "age1admin"}]
    end

    test "passes the domain through when given" do
      {scope, runner} = recording_scope({"done", 0})

      Host.provision_app(scope, %{name: "app1", port: 4001, domain: "app1.example.com"},
        admin_age_pubkey: "age1admin",
        cmd: runner
      )

      assert_received {:cmd, _command, ["app1", "4001", "app1.example.com"], _opts}
    end

    test "reports a non-zero exit as an error carrying the output" do
      {scope, runner} = recording_scope({"createuser: role exists", 1})

      assert {:error, message} =
               Host.provision_app(scope, %{name: "app1", port: 4001},
                 admin_age_pubkey: "age1admin",
                 cmd: runner
               )

      assert message =~ "exit 1"
      assert message =~ "role exists"
    end
  end

  describe "verify_isolation/3" do
    # The exit code is the whole signal: the script exits non-zero if any
    # isolation check fails, so this can gate a deploy rather than being read
    # by a human.
    test "an all-clear exit is success" do
      {scope, runner} = recording_scope({"5 passed, 0 failed", 0})

      assert {:ok, report} = Host.verify_isolation(scope, "app1", "app2", cmd: runner)
      assert report =~ "passed"
      assert_received {:cmd, command, ["app1", "app2"], _opts}
      assert command =~ "verify_isolation.sh"
    end

    @tag :capture_log
    test "a non-zero exit is a failure — an isolation breach must not read as ok" do
      {scope, runner} = recording_scope({"app1 CONNECTED to database app2", 1})

      assert {:error, report} = Host.verify_isolation(scope, "app1", "app2", cmd: runner)
      assert report =~ "CONNECTED"
    end
  end

  describe "a scope with no environment" do
    test "cannot run and says so rather than crashing" do
      scope = %Scope{environment: nil, active_project_id: "p1"}

      assert {:error, message} =
               Host.provision_app(scope, %{name: "app1", port: 4001}, admin_age_pubkey: "age1admin")

      _ = message

      assert message =~ "no environment" or message =~ "exit"
    end
  end
end
