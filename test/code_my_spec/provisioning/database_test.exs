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

  defp credential, do: %{username: "app_sam_s_app", password: "pw", database: "app_sam_s_app_uat"}
  defp admin_credential, do: %{username: "postgres", password: "adminpw"}

  defp serve(opts \\ []) do
    Database.serve(
      scope(),
      "uat",
      Keyword.merge(
        [
          run: recorder(self()),
          database_credential: credential(),
          database_admin_credential: admin_credential()
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

  describe "serve/3" do
    # The app and the database share a docker network, which is what the
    # generated kamal config already expects — `network: db_net`.
    test "joins the network the app is already on" do
      assert {:ok, %{host: "cms-postgres"}} = serve()

      commands = collect_commands()
      assert Enum.any?(commands, &(&1 =~ "--network db_net"))
      assert Enum.any?(commands, &(&1 =~ "docker network create db_net"))
    end

    # Re-running setup must not be a way to lose data, so the volume is named
    # rather than left for docker to generate — a generated one is orphaned
    # with the container it belonged to.
    test "the data outlives the container" do
      assert {:ok, _} = serve()

      commands = collect_commands()
      assert Enum.any?(commands, &(&1 =~ "-v cms-postgres-data:/var/lib/postgresql/data"))
      assert Enum.any?(commands, &(&1 =~ "docker rm -f cms-postgres"))
    end

    # An already-running container is left alone rather than restarted —
    # sharing the box with a second project means someone else may be
    # connected to it right now, and destroying it to "ensure" it is there is
    # the opposite of ensuring anything.
    test "an already-running container is not touched" do
      run = fn
        ["docker ps -q -f name=" <> _] -> {"c0ffee", 0}
        ["docker network create" <> _] -> raise "must not touch an already-running container"
        [_] -> {"", 0}
      end

      assert {:ok, _} = serve(run: run)
    end

    # Never published to a host port. The firewall would refuse it from
    # outside, and a database not listening on an address cannot be reached by
    # mistake.
    test "is not reachable from outside the box" do
      assert {:ok, _} = serve()

      commands = collect_commands()
      refute Enum.any?(commands, &(&1 =~ "-p "))
      refute Enum.any?(commands, &(&1 =~ "5432:5432"))
    end

    # A database that silently changes major version between two runs of setup
    # is a data-loss event with a convenient explanation.
    test "the version is pinned" do
      assert {:ok, _} = serve()

      commands = collect_commands()
      assert Enum.any?(commands, &(&1 =~ "postgres:17"))
      refute Enum.any?(commands, &(&1 =~ "postgres:latest"))
    end

    # The container is bootstrapped with the administrator, not the tenant —
    # the tenant's own role does not exist yet on a box it has never reached
    # before, so it cannot be the credential the image is created with.
    test "the container is bootstrapped with the administrator's credential" do
      assert {:ok, _} = serve()

      commands = collect_commands()
      assert Enum.any?(commands, &(&1 =~ "-e POSTGRES_USER='postgres'"))
      assert Enum.any?(commands, &(&1 =~ "-e POSTGRES_PASSWORD='adminpw'"))
      refute Enum.any?(commands, &(&1 =~ "POSTGRES_USER='app_sam_s_app'"))
    end

    # `docker run -d` returning 0 means the container was created. Postgres
    # takes seconds more to accept connections, and a migration that arrives
    # first fails in a way that reads like a broken image.
    test "waits until it actually accepts connections" do
      assert {:ok, _} = serve()

      commands = collect_commands()
      assert Enum.any?(commands, &(&1 =~ "pg_isready"))
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

    # Ensuring the database is a check-then-create, not a blind create — a
    # `CREATE DATABASE` on one that already exists is a Postgres error, and
    # that is the ordinary case for a project provisioning its second
    # environment against a box it already has a role on.
    test "does not try to create the database again once it already exists" do
      run = fn
        ["docker exec" <> _ = cmd] ->
          if cmd =~ "SELECT 1 FROM pg_database" do
            {"1", 0}
          else
            {"", 0}
          end

        [_] ->
          {"", 0}
      end

      assert {:ok, _} = serve(run: run)
    end

    test "a database that never comes up brings back its own logs" do
      run = fn
        ["docker exec" <> _] -> {"", 1}
        ["docker logs" <> _] -> {"FATAL: data directory has wrong ownership", 0}
        [_] -> {"", 0}
      end

      assert {:error, {:database_not_ready, "cms-postgres", logs}} =
               serve(run: run, database_attempts: 2)

      assert logs =~ "wrong ownership"
    end

    test "a container that will not start is an error, not a success" do
      assert {:error, {:database_start_failed, 125, _}} = serve(run: recorder(self(), 125))
    end
  end

  describe "url/1" do
    # By container name rather than address: the app and the database share a
    # network, and an address would be a second thing to keep correct whenever
    # either is recreated.
    test "addresses the database by the name the app can resolve" do
      assert Database.url(credential()) == "ecto://app_sam_s_app:pw@cms-postgres/app_sam_s_app_uat"
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
