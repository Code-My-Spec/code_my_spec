defmodule CodeMySpec.Provisioning.BaselineLocalTest do
  @moduledoc """
  The baseline containers, started for real, on this machine.

  `Registry` and `Database` are unit-tested with `:run` injected, which proves
  we ask for the right commands. It does not prove those commands work — and
  that gap is the expensive one. `Builder.Remote.ssh_runner/2` required an
  `:env` option that *nothing anywhere supplied*, and the suite was green the
  whole time: a recording cannot tell "this works" from "this has never run".
  Seventeen defects surfaced one per ten-minute cloud drill before this layer
  existed.

  So this runs the same functions with `local_runner/1` instead of an SSH
  runner. Same commands, same code path, real `distribution` and real
  Postgres, on the loopback interface. No Hetzner, no bucket, no cost.

  What it still does not cover, and what a cloud drill is for: whether Hetzner
  offers a server type in a location, whether a private subnet spans zones,
  whether a cloud firewall passes private traffic. Those are facts about the
  cloud and only the cloud can answer them.

  Tagged `:docker` and excluded by default — `mix test` does not start
  containers. Run it deliberately:

      mix test test/code_my_spec/provisioning/baseline_local_test.exs --include docker
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Provisioning.Builder.Remote
  alias CodeMySpec.Provisioning.Database
  alias CodeMySpec.Provisioning.Registry
  alias CodeMySpec.Users.Scope

  @moduletag :docker
  @moduletag timeout: 300_000

  defp scope, do: %Scope{active_project: %{name: "Baseline Local"}}

  defp runner, do: Remote.local_runner(cd: System.tmp_dir!())

  defp docker(args) do
    System.cmd("docker", args, stderr_to_stdout: true)
  end

  defp credential, do: %{username: "cms", password: "hunter2"}

  # Under the project rather than in the system temp directory. On macOS
  # `System.tmp_dir!/0` is `/var/folders/...`, which is a symlink to
  # `/private/var/folders/...`; Docker Desktop does not follow it, so the bind
  # mount silently creates a *directory* at the path and `distribution` then
  # refuses every request with "read /auth/htpasswd: is a directory".
  defp auth_dir, do: Path.join(File.cwd!(), "tmp/cms-registry-test")

  setup do
    # A failed run leaves docker's own creation behind: bind-mounting a path
    # that does not exist makes a *directory* there, and the next run's
    # `printf >` cannot write over it. Clearing it is what makes this
    # repeatable rather than green only on a clean machine.
    File.rm_rf(auth_dir())

    on_exit(fn ->
      docker(["rm", "-f", "cms-registry"])
      docker(["rm", "-f", "cms-postgres"])
      docker(["volume", "rm", "-f", "cms-postgres-data"])
      File.rm_rf(auth_dir())
    end)

    :ok
  end

  describe "the registry we provision actually serves" do
    test "it starts, demands the credential, and round-trips an image" do
      assert {:ok, served} =
               Registry.serve(scope(),
                 run: runner(),
                 storage: :filesystem,
                 credentials: [access_key_id: "unused", secret_access_key: "unused"],
                 registry_credentials: credential(),
                 bind: "127.0.0.1",
                 # `/etc` needs root on a developer's machine. The path is the
                 # only thing that differs from the server; everything the
                 # command does is the same.
                 auth_dir: auth_dir()
               )

      assert served.port == 5000

      # `serve/2` only returns once its own probe answered, so the registry is
      # up by here. Anonymous access must not be.
      {_out, status} = docker(["run", "--rm", "--network", "host", "curlimages/curl:8.11.1",
                               "-sf", "http://127.0.0.1:5000/v2/"])

      refute status == 0, "an unauthenticated read succeeded — the htpasswd file is not in force"

      # And the credential opens it.
      {_out, status} =
        docker(["run", "--rm", "--network", "host", "curlimages/curl:8.11.1",
                "-sf", "-u", "cms:hunter2", "http://127.0.0.1:5000/v2/"])

      assert status == 0, "the credential setup minted does not open the registry it configured"

      # A real push and pull, which is the only thing that proves the storage
      # driver and the auth agree with each other.
      reference = "127.0.0.1:5000/baseline:probe"

      {_, 0} = docker(["pull", "alpine:3"])
      {_, 0} = docker(["tag", "alpine:3", reference])
      {_, 0} = docker(["login", "127.0.0.1:5000", "-u", "cms", "-p", "hunter2"])

      assert {_, 0} = docker(["push", reference]),
             "the registry we configure cannot accept the image we build"

      {_, 0} = docker(["rmi", "-f", reference])

      assert {_, 0} = docker(["pull", reference]),
             "the deploy pulls from here — an image that pushes and will not pull is worse than neither"
    end
  end

  describe "the database we provision actually accepts connections" do
    test "it starts, and the URL we write is the one that works" do
      assert {:ok, served} =
               Database.serve(scope(), "uat",
                 run: runner(),
                 database_credential: %{username: "app", password: "pw", database: "app_uat"}
               )

      assert served.host == "cms-postgres"

      # `serve/3` waits on pg_isready, so it is accepting connections by here.
      # What that does not prove is that the URL we hand the app describes the
      # same database — so connect with exactly that, from a container on the
      # same network the app will be on.
      # `ecto://` is Ecto's scheme and psql does not know it. The URL the app
      # gets is right; the client used here needs the standard one.
      url =
        %{username: "app", password: "pw", database: "app_uat"}
        |> Database.url()
        |> String.replace_prefix("ecto://", "postgresql://")

      {out, status} =
        docker([
          "run",
          "--rm",
          "--network",
          Database.network(),
          "-e",
          "PGPASSWORD=pw",
          "postgres:17",
          "psql",
          url,
          "-tAc",
          "select current_database()"
        ])

      assert status == 0, "the URL setup writes into the encrypted env does not connect: #{out}"
      assert String.trim(out) =~ "app_uat"
    end

    test "the data survives the container being replaced" do
      opts = [
        run: runner(),
        database_credential: %{username: "app", password: "pw", database: "app_uat"}
      ]

      assert {:ok, _} = Database.serve(scope(), "uat", opts)

      url =
        %{username: "app", password: "pw", database: "app_uat"}
        |> Database.url()
        |> String.replace_prefix("ecto://", "postgresql://")

      psql = fn sql ->
        docker([
          "run", "--rm", "--network", Database.network(),
          "-e", "PGPASSWORD=pw", "postgres:17", "psql", url, "-tAc", sql
        ])
      end

      {_, 0} = psql.("create table survived (id int)")
      {_, 0} = psql.("insert into survived values (1)")

      # Re-running setup replaces the container. The volume is named precisely
      # so that this is not how data is lost.
      assert {:ok, _} = Database.serve(scope(), "uat", opts)

      {out, status} = psql.("select count(*) from survived")

      assert status == 0, "the table is gone — re-running setup destroyed the data: #{out}"
      assert String.trim(out) == "1"
    end
  end
end
