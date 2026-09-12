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

  # `local_runner/1` shells out on this machine — right for `docker` itself,
  # since the CLI already talks to whichever daemon the active context names
  # regardless of where the shell runs. Wrong for `ensure_htpasswd/3`'s plain
  # `mkdir`/`touch`/`chmod`: those touch *this* filesystem, and under Colima
  # that daemon lives in a Linux VM whose own filesystem is not the host's —
  # only `$HOME`, virtiofs-shared, is. A path under it crosses that boundary
  # and hits a uid the VM and the host disagree about (dd1f932c); a path
  # nowhere in the VM's filesystem at all just gets Docker's usual "bind-mount
  # a path that isn't there yet" trap, an empty directory instead of a file.
  #
  # So under Colima specifically, every command in this suite — including the
  # `docker` ones, for one runner rather than two — runs inside that same VM
  # instead, where `auth_dir/0`'s plain `/tmp` path is genuinely native.
  # Anything else (Docker Desktop, a native Linux daemon) keeps running
  # locally, where `/tmp` is already real.
  defp runner, do: build_runner(colima_profile())

  defp build_runner(nil), do: Remote.local_runner(cd: System.tmp_dir!())
  defp build_runner(profile), do: colima_runner(profile)

  defp colima_profile do
    "docker"
    |> System.cmd(["context", "show"], stderr_to_stdout: true)
    |> parse_colima_profile()
  end

  defp parse_colima_profile({"colima-" <> profile, 0}), do: String.trim(profile)
  defp parse_colima_profile(_result), do: nil

  # `sudo`, because a real box's own SSH connects as root
  # (`Remote.ssh_args/2`) — Docker itself auto-creates a bind mount's source
  # as root the moment a container asks for a path that is not there yet
  # (`ensure_container/2` starts the registry before any project's `serve/2`
  # has written a real htpasswd, so this always happens first). Without
  # `sudo` here, the `colima ssh` user (a plain uid) cannot even write into
  # what Docker just made, which reads as a second, unrelated permission bug
  # rather than the same "not root" gap `ssh_args/2` already closed for a
  # real deploy.
  defp colima_runner(profile) do
    fn [command] ->
      System.cmd(
        "colima",
        ["ssh", "--profile", profile, "--", "sudo", "sh", "-c", command],
        stderr_to_stdout: true
      )
    end
  end

  defp docker(args) do
    System.cmd("docker", args, stderr_to_stdout: true)
  end

  defp credential, do: %{username: "cms", password: "hunter2"}

  # Supplied rather than resolved, the same way `database_credential:` already
  # is throughout this file.
  #
  # `serve/3` falls back to `admin_credential/1`, which reads the account's
  # `database_admin_password` secret and needs `active_account_id` to be a
  # binary. This suite is `use ExUnit.Case` with no sandbox, so there is no
  # account to read one from — every call crashed with a FunctionClauseError
  # before reaching the docker work these tests exist to prove (2c63bf0d).
  #
  # It predates the shared-box work: fa2af563 added the AccountSecrets-backed
  # admin credential, and this suite is `:docker`-tagged and excluded by
  # default, so nothing caught it.
  #
  # Explicit beats a fixture account here. What these tests prove is that the
  # commands work against real Postgres; where the admin password comes from is
  # a different question, covered elsewhere, and threading a database fixture
  # through a suite with no Repo would make the setup the hardest part of it.
  #
  # `postgres` is `@admin_username` in `Database`, and it is the role
  # `POSTGRES_USER` creates at first boot — so this is the superuser the
  # container actually has, not a stand-in.
  defp admin_credential, do: %{username: "postgres", password: "postgres"}

  # And the restore role, for the same reason one function further on.
  #
  # The issue found the admin credential and stopped there, because that is
  # where the first crash was. Supplying it only moved the crash:
  # `restore_credential/2` reaches `ProjectSecrets`, which wants
  # `active_project_id` to be a binary, and this scope has no project row
  # either. Both are the same gap — a scope built for a suite that predates
  # both secret stores.
  defp restore_credential, do: %{username: "app_baseline_restore", password: "restore-pw"}

  # Plain `/tmp`, not `System.tmp_dir!/0` (`/var/folders/<random>/T/...` on
  # macOS) and not under the project checkout either.
  #
  # `/var/folders/...` was the first thing tried: Docker Desktop does not
  # follow that symlink, so the bind mount silently creates a *directory* at
  # the path instead of finding the file, and `distribution` then refuses
  # every request with "read /auth/htpasswd: is a directory". Moving it under
  # the checkout (`File.cwd!()`) fixed that and broke something worse under
  # Colima specifically: that path is virtiofs-shared into the VM the daemon
  # actually runs in, and a file `chmod 600`'d by the host user crosses that
  # boundary as a uid the VM's own root does not recognize as the same user —
  # "permission denied: open /auth/htpasswd" (dd1f932c), a property of the
  # sharing rather than of anything this suite does wrong.
  #
  # `runner/0` now runs every command for this suite inside the Colima VM
  # when that is the active context, so a bare `/tmp` path here is created
  # natively wherever the commands actually run — the VM's own `/tmp` under
  # Colima, this host's under Docker Desktop or a native daemon — never
  # crossing the virtiofs boundary that caused either failure.
  defp auth_dir, do: "/tmp/cms-registry-test"

  setup do
    # A failed run leaves docker's own creation behind: bind-mounting a path
    # that does not exist makes a *directory* there, and the next run's
    # `printf >` cannot write over it. Clearing it is what makes this
    # repeatable rather than green only on a clean machine.
    #
    # Through `runner/0`, not `File.rm_rf/1` — under Colima, `auth_dir/0`
    # names a path inside the VM, which a bare `File` call on this host
    # cannot see at all.
    clear_auth_dir()

    # And pre-create a real, empty file at the mount source, for the ordering
    # this suite's own two calls have and a real box does not: a real
    # `:server` step's `serve/2` writes the credential before `docker run`
    # ever asks for it. Here `ensure_container/2` starts the registry first
    # (it is account-wide, deliberately deployed before any one project's
    # `serve/2`), so the very first thing to touch this path is Docker's own
    # bind-mount, on a path that does not exist yet — which makes a
    # *directory* there, and no `touch` afterward turns a directory into a
    # file.
    runner().(["mkdir -p #{auth_dir()} && touch #{auth_dir()}/htpasswd"])

    on_exit(fn ->
      docker(["rm", "-f", "cms-registry"])
      docker(["rm", "-f", "cms-postgres"])
      docker(["volume", "rm", "-f", "cms-postgres-data"])
      clear_auth_dir()
    end)

    :ok
  end

  defp clear_auth_dir, do: runner().(["rm -rf #{auth_dir()}"])

  describe "the registry we provision actually serves" do
    test "it starts, demands the credential, and round-trips an image" do
      # Same split as the database: the container is account infrastructure,
      # `serve/2` only configures this project against an already-running one.
      assert {:ok, _} =
               Registry.ensure_container(scope(),
                 run: runner(),
                 storage: :filesystem,
                 credentials: [access_key_id: "unused", secret_access_key: "unused"],
                 registry_credentials: credential(),
                 bind: "127.0.0.1",
                 auth_dir: auth_dir()
               )

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
      {_out, status} =
        docker([
          "run",
          "--rm",
          "--network",
          "host",
          "curlimages/curl:8.11.1",
          "-sf",
          "http://127.0.0.1:5000/v2/"
        ])

      refute status == 0, "an unauthenticated read succeeded — the htpasswd file is not in force"

      # And the credential opens it.
      {_out, status} =
        docker([
          "run",
          "--rm",
          "--network",
          "host",
          "curlimages/curl:8.11.1",
          "-sf",
          "-u",
          "cms:hunter2",
          "http://127.0.0.1:5000/v2/"
        ])

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

  # The container first, the tenant second — that is the split now.
  #
  # `serve/3` used to do both. It refuses rather than creating one now, because
  # a project's own devops step does not get to stand up shared account
  # infrastructure as a side effect of asking for its own role and database.
  # This suite still called `serve/3` alone and got `:database_not_provisioned`
  # from every test, which reads as "the container is broken" and means "nobody
  # asked for one".
  defp start_database do
    assert {:ok, _} =
             Database.ensure_container(scope(),
               run: runner(),
               database_admin_credential: admin_credential()
             )
  end

  describe "the database we provision actually accepts connections" do
    test "it starts, and the URL we write is the one that works" do
      start_database()

      assert {:ok, served} =
               Database.serve(scope(), "uat",
                 run: runner(),
                 database_admin_credential: admin_credential(),
                 database_restore_credential: restore_credential(),
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
          "pgvector/pgvector:pg18",
          "psql",
          url,
          "-tAc",
          "select current_database()"
        ])

      assert status == 0, "the URL setup writes into the encrypted env does not connect: #{out}"
      assert String.trim(out) =~ "app_uat"
    end

    test "the data survives the container being replaced" do
      start_database()

      opts = [
        run: runner(),
        database_admin_credential: admin_credential(),
        database_restore_credential: restore_credential(),
        database_credential: %{username: "app", password: "pw", database: "app_uat"}
      ]

      assert {:ok, _} = Database.serve(scope(), "uat", opts)

      url =
        %{username: "app", password: "pw", database: "app_uat"}
        |> Database.url()
        |> String.replace_prefix("ecto://", "postgresql://")

      psql = fn sql ->
        docker([
          "run",
          "--rm",
          "--network",
          Database.network(),
          "-e",
          "PGPASSWORD=pw",
          "pgvector/pgvector:pg18",
          "psql",
          url,
          "-tAc",
          sql
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
