defmodule CodeMySpec.Provisioning.DatabaseTest do
  @moduledoc """
  What the database step asks the box to do.

  Tested the way `Builder.Remote` is: `:run` takes the command and returns
  `{output, status}`, so the commands are assertable and running them is not.
  Starting a real Postgres would make this a container test and prove nothing
  about what we asked for.

  This step exists because nothing provisioned a database at all — `backups`
  ran `pg_dump` against one that did not exist, and the generated kamal config
  put the app on a `db_net` network with nothing else on it.

  `ensure_container/2` (account-side: the box-wide container, run once
  regardless of which project asks) and `serve/3` (project-side: this
  project's own role and database on an already-running container) used to
  be one function. Split so a project's own devops step can never stand up
  shared account infrastructure as a side effect of asking for its own
  tenant — the same reasoning `Steps.server_creation_gate/3` applies to the
  server itself.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Provisioning.Database
  alias CodeMySpec.Users.Scope

  defp scope, do: %Scope{active_project: %{name: "Sam's App", id: Ecto.UUID.generate()}}

  # Empty output, exit 0, for every command — the shape a fresh, empty box
  # answers with: no container running yet, no role, no database. Good enough
  # for the tests that are about what gets asked for rather than about a
  # specific box's existing state.
  defp recorder(owner, status \\ 0) do
    fn [command] ->
      send(owner, {:ran, command})
      {"", status}
    end
  end

  # The container already up and answered for, the shape every `serve/3` call
  # sees in the ordinary case — someone else's (or this project's own
  # earlier) `ensure_container/2` already ran.
  defp running_recorder(owner, status \\ 0) do
    fn [command] ->
      send(owner, {:ran, command})
      running_response(command, status)
    end
  end

  defp running_response("docker ps -q -f name=" <> _, _status), do: {"c0ffeec0ffee", 0}
  defp running_response(_command, status), do: {"", status}

  defp ps_banner_response("docker ps -q -f name=" <> _),
    do: {"Warning: Permanently added '1.2.3.4' (ED25519) to the list of known hosts.\r\n", 0}

  defp ps_banner_response(_command), do: {"", 0}

  defp credential, do: %{username: "app_sam_s_app", password: "pw", database: "app_sam_s_app_uat"}
  defp admin_credential, do: %{username: "postgres", password: "adminpw"}
  defp restore_credential, do: %{username: "app_sam_s_app_restore", password: "restorepw"}

  defp ensure_container(opts \\ []) do
    Database.ensure_container(
      scope(),
      Keyword.merge(
        [run: recorder(self()), database_admin_credential: admin_credential()],
        opts
      )
    )
  end

  defp serve(opts \\ []) do
    Database.serve(
      scope(),
      "uat",
      Keyword.merge(
        [
          run: running_recorder(self()),
          database_credential: credential(),
          database_admin_credential: admin_credential(),
          database_restore_credential: restore_credential()
        ],
        opts
      )
    )
  end

  defp collect_commands(acc \\ []) do
    receive do
      {:ran, command} -> collect_commands([command | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "ensure_container/2" do
    # The app and the database share a docker network, which is what the
    # generated kamal config already expects — `network: db_net`.
    test "joins the network the app is already on" do
      assert {:ok, %{host: "cms-postgres"}} = ensure_container()

      commands = collect_commands()
      assert Enum.any?(commands, &(&1 =~ "--network db_net"))
      assert Enum.any?(commands, &(&1 =~ "docker network create db_net"))
    end

    # Re-running setup must not be a way to lose data, so the volume is named
    # rather than left for docker to generate — a generated one is orphaned
    # with the container it belonged to.
    test "the data outlives the container" do
      assert {:ok, _} = ensure_container()

      commands = collect_commands()
      assert Enum.any?(commands, &(&1 =~ "-v cms-postgres-data:/var/lib/postgresql "))
      assert Enum.any?(commands, &(&1 =~ "docker rm -f cms-postgres"))
    end

    # pg18's official image moved to a pg_ctlcluster-style layout and now
    # refuses to start at all — crash-looping, not merely warning — when it
    # finds a volume mounted at the pg17-and-earlier path one level too deep.
    # Confirmed live: cms-postgres crash-looped against a brand new, empty
    # volume on exactly this mount, with the image already correctly on
    # pgvector/pgvector:pg18 — the mount depth was the whole complaint.
    # docker-library/postgres#1259.
    test "the volume mounts where pg18 actually expects it, not one level deeper" do
      assert {:ok, _} = ensure_container()

      commands = collect_commands()

      refute Enum.any?(commands, &(&1 =~ "/var/lib/postgresql/data")),
             "mounting at .../data is the pg17-and-earlier convention — pg18 refuses to boot on it"
    end

    # An already-running container is left alone rather than restarted —
    # sharing the box with a second project means someone else may be
    # connected to it right now, and destroying it to "ensure" it is there is
    # the opposite of ensuring anything.
    test "an already-running container is not touched" do
      run = fn
        ["docker ps -q -f name=" <> _] -> {"c0ffeec0ffee", 0}
        ["docker inspect" <> _] -> {"pgvector/pgvector:pg18", 0}
        ["docker network create" <> _] -> raise "must not touch an already-running container"
        [_] -> {"", 0}
      end

      assert {:ok, _} = ensure_container(run: run)
    end

    # Found live against fuellytics-prod: cms-postgres was started on plain
    # postgres:17 before pgvector became the default, and an already-running
    # container was never checked against what a fresh one would use — every
    # run since would have kept reporting the server step done on a database
    # that could never install `vector`. This never auto-recreates the
    # container: the volume may hold another project's real data, so drift
    # becomes a step that fails to verify rather than a silent swap.
    test "a running container on an outdated image refuses rather than reporting done" do
      run = fn
        ["docker ps -q -f name=" <> _] -> {"c0ffeec0ffee", 0}
        ["docker inspect" <> _] -> {"postgres:17", 0}
        [_] -> {"", 0}
      end

      assert {:error, {:database_image_outdated, message}} = ensure_container(run: run)
      assert message =~ "postgres:17"
      assert message =~ "pgvector/pgvector:pg18"
    end

    # An inspect that cannot be read is not evidence of drift either way —
    # the same rule already applied to a provider that could not be read —
    # so this proceeds rather than blocking setup on a transient SSH hiccup.
    test "an inspect that cannot be read does not block setup" do
      run = fn
        ["docker ps -q -f name=" <> _] -> {"c0ffeec0ffee", 0}
        ["docker inspect" <> _] -> {"Error: No such object: cms-postgres", 1}
        [_] -> {"", 0}
      end

      assert {:ok, _} = ensure_container(run: run)
    end

    # Found live against fuellytics-prod: ssh's own "Warning: Permanently
    # added ... to the list of known hosts" banner merges onto the same
    # stream as the command's real output (`UserKnownHostsFile=/dev/null`
    # guarantees it prints every time), so a box with nothing on it answered
    # "docker ps -q" with banner text instead of silence — non-empty, but not
    # a container id. `create_container/3` never ran at all.
    test "banner noise on the ps check is not mistaken for a running container" do
      run = fn [command] ->
        send(self(), {:ran, command})
        ps_banner_response(command)
      end

      assert {:ok, _} = ensure_container(run: run)
      assert collect_commands() |> Enum.any?(&(&1 =~ "docker run -d --name cms-postgres"))
    end

    # Never published to a host port. The firewall would refuse it from
    # outside, and a database not listening on an address cannot be reached by
    # mistake.
    test "is not reachable from outside the box" do
      assert {:ok, _} = ensure_container()

      commands = collect_commands()
      refute Enum.any?(commands, &(&1 =~ "-p "))
      refute Enum.any?(commands, &(&1 =~ "5432:5432"))
    end

    # A database that silently changes major version between two runs of setup
    # is a data-loss event with a convenient explanation.
    test "the version is pinned" do
      assert {:ok, _} = ensure_container()

      commands = collect_commands()
      assert Enum.any?(commands, &(&1 =~ "pgvector/pgvector:pg18"))
      refute Enum.any?(commands, &(&1 =~ "postgres:latest"))
    end

    # The container is bootstrapped with the administrator, not a tenant — no
    # tenant role exists yet on a box nothing has reached before, so it
    # cannot be the credential the image is created with.
    test "the container is bootstrapped with the administrator's credential" do
      assert {:ok, _} = ensure_container()

      commands = collect_commands()
      assert Enum.any?(commands, &(&1 =~ "-e POSTGRES_USER='postgres'"))
      assert Enum.any?(commands, &(&1 =~ "-e POSTGRES_PASSWORD='adminpw'"))
      refute Enum.any?(commands, &(&1 =~ "POSTGRES_USER='app_sam_s_app'"))
    end

    # `docker run -d` returning 0 means the container was created. Postgres
    # takes seconds more to accept connections, and a migration that arrives
    # first fails in a way that reads like a broken image.
    test "waits until it actually accepts connections" do
      assert {:ok, _} = ensure_container()

      commands = collect_commands()
      assert Enum.any?(commands, &(&1 =~ "pg_isready"))
    end

    # pgvector is not a trusted extension — a plain LOGIN role can never
    # install it itself, even as the owner of its own database. Confirmed
    # live: "permission denied to create extension ... Must be superuser".
    # Installed once here, by the admin, into template1 — so every tenant
    # database `CREATE DATABASE` hands it to already carries the extension,
    # and the app's own `CREATE EXTENSION IF NOT EXISTS vector` migration
    # never has to ask for a privilege its own role could never hold.
    test "the vector extension is installed into template1, box-wide, by the admin" do
      assert {:ok, _} = ensure_container()

      commands = collect_commands()

      assert Enum.any?(
               commands,
               &(&1 =~ "-U 'postgres' -d 'template1' -c 'CREATE EXTENSION IF NOT EXISTS vector'")
             )
    end

    test "a database that never comes up brings back its own logs" do
      run = fn
        ["docker exec" <> _] -> {"", 1}
        ["docker logs" <> _] -> {"FATAL: data directory has wrong ownership", 0}
        [_] -> {"", 0}
      end

      assert {:error, {:database_not_ready, "cms-postgres", logs}} =
               ensure_container(run: run, database_attempts: 2)

      assert logs =~ "wrong ownership"
    end

    test "a container that will not start is an error, not a success" do
      assert {:error, {:database_start_failed, 125, _}} =
               ensure_container(run: recorder(self(), 125))
    end
  end

  describe "serve/3" do
    # A project's own devops step does not get to stand up shared account
    # infrastructure as a side effect of asking for its own tenant — the same
    # shape `Steps.server_creation_gate/3` uses for the server itself.
    # `ensure_container/2` is the only thing that may create it.
    test "refuses instead of creating the container if it is not already running" do
      assert {:error, :database_not_provisioned} = serve(run: recorder(self()))
    end

    # The role and database are this project's own, created (not assumed)
    # every time — the box may already have another project's role on it, and
    # the first time this project reaches it, nothing here exists yet.
    test "ensures this project's own role and database exist" do
      assert {:ok, _} = serve()

      commands = collect_commands()
      assert Enum.any?(commands, &(&1 =~ "CREATE ROLE app_sam_s_app"))
      assert Enum.any?(commands, &(&1 =~ "CREATE DATABASE app_sam_s_app_uat OWNER app_sam_s_app"))
    end

    # Confirmed live, on every project this shared box has ever served, not
    # a broken_oaths quirk: backup restore-verification needs CREATE/DROP
    # DATABASE for its scratch copy (deploy_artifacts.ex's generated
    # bin/backup), which only CREATEDB or an administrator may do — but a
    # second, narrower role gets it, never the app's own. The running
    # application authenticates with its own role on every request, and
    # that is exactly the credential a SQL injection or a dependency
    # vulnerability would first reach; a standing ability to create
    # databases is a privilege the application itself never uses, so it
    # never carries it.
    test "grants a second, restore-only role CREATEDB — never the app's own role" do
      assert {:ok, _} = serve()

      commands = collect_commands()
      assert Enum.any?(commands, &(&1 =~ "ALTER ROLE app_sam_s_app_restore CREATEDB"))
      refute Enum.any?(commands, &(&1 =~ "ALTER ROLE app_sam_s_app CREATEDB"))
    end

    test "the restore role is created if it does not already exist, but owns no database of its own" do
      assert {:ok, _} = serve()

      commands = collect_commands()
      assert Enum.any?(commands, &(&1 =~ "CREATE ROLE app_sam_s_app_restore LOGIN"))
      refute Enum.any?(commands, &(&1 =~ "CREATE DATABASE" and &1 =~ "app_sam_s_app_restore"))
    end

    # `sync_password/2`'s own reasoning: a rotated restore-role password
    # left silently out of sync would fail the very next backup restore-
    # verification with an authentication error, pointing at the wrong
    # step.
    test "keeps the restore role's password in sync on every run" do
      assert {:ok, _} = serve()

      commands = collect_commands()

      assert Enum.any?(
               commands,
               &(&1 =~ "ALTER USER app_sam_s_app_restore WITH PASSWORD" and &1 =~ "-d postgres")
             )
    end

    # pgvector is not a trusted extension — a plain LOGIN role can never
    # install it itself, even as the owner of its own database. Confirmed
    # live: "permission denied to create extension ... Must be superuser".
    # `ensure_container/2` already installed it into template1, box-wide, so
    # this project's own database inherits it at creation — but the
    # extension is still asserted here explicitly, once, in case this
    # project's database predates that box-wide install.
    test "the vector extension is installed by the admin, in this project's own database" do
      assert {:ok, _} = serve()

      commands = collect_commands()

      assert Enum.any?(
               commands,
               &(&1 =~
                   "-U 'postgres' -d 'app_sam_s_app_uat' -c 'CREATE EXTENSION IF NOT EXISTS vector'")
             )
    end

    # Ensuring the database is a check-then-create, not a blind create — a
    # `CREATE DATABASE` on one that already exists is a Postgres error, and
    # that is the ordinary case for a project provisioning its second
    # environment against a box it already has a role on.
    test "does not try to create the database again once it already exists" do
      run = fn
        ["docker ps -q -f name=" <> _] ->
          {"c0ffeec0ffee", 0}

        ["docker exec" <> _ = cmd] ->
          role_exists_response(String.contains?(cmd, "SELECT 1 FROM pg_database"))

        [_] ->
          {"", 0}
      end

      assert {:ok, _} = serve(run: run)
    end

    defp role_exists_response(true), do: {"1", 0}
    defp role_exists_response(false), do: {"", 0}
  end

  describe "url/1" do
    # By container name rather than address: the app and the database share a
    # network, and an address would be a second thing to keep correct whenever
    # either is recreated.
    test "addresses the database by the name the app can resolve" do
      assert Database.url(credential()) ==
               "ecto://app_sam_s_app:pw@cms-postgres/app_sam_s_app_uat"
    end
  end

  describe "credential/2" do
    # The same separation the age keys have, for the same reason: a migration
    # tested against one environment must not have already run against the
    # other.
    test "each environment gets its own database" do
      # The database name carries the environment, so one connection string
      # cannot reach the other environment's data.
      uat = Database.url(%{username: "app", password: "p", database: "app_uat"})
      prod = Database.url(%{username: "app", password: "p", database: "app_prod"})

      assert uat =~ "/app_uat"
      assert prod =~ "/app_prod"
      refute uat == prod
    end
  end
end
