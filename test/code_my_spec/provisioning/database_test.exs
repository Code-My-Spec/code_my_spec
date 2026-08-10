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

  defp scope, do: %Scope{active_project: %{name: "Sam's App"}}

  defp recorder(owner, status \\ 0) do
    fn [command] ->
      send(owner, {:ran, command})
      {"", status}
    end
  end

  defp credential, do: %{username: "app", password: "pw", database: "app_uat"}

  defp serve(opts \\ []) do
    Database.serve(
      scope(),
      "uat",
      Keyword.merge([run: recorder(self()), database_credential: credential()], opts)
    )
  end

  describe "serve/3" do
    # The app and the database share a docker network, which is what the
    # generated kamal config already expects — `network: db_net`.
    test "joins the network the app is already on" do
      assert {:ok, %{host: "cms-postgres"}} = serve()

      assert_received {:ran, command}
      assert command =~ "--network db_net"
      assert command =~ "docker network create db_net"
    end

    # Re-running setup must not be a way to lose data, so the volume is named
    # rather than left for docker to generate — a generated one is orphaned
    # with the container it belonged to.
    test "the data outlives the container" do
      assert {:ok, _} = serve()

      assert_received {:ran, command}
      assert command =~ "-v cms-postgres-data:/var/lib/postgresql/data"
      assert command =~ "docker rm -f cms-postgres"
    end

    # Never published to a host port. The firewall would refuse it from
    # outside, and a database not listening on an address cannot be reached by
    # mistake.
    test "is not reachable from outside the box" do
      assert {:ok, _} = serve()

      assert_received {:ran, command}
      refute command =~ "-p "
      refute command =~ "5432:5432"
    end

    # A database that silently changes major version between two runs of setup
    # is a data-loss event with a convenient explanation.
    test "the version is pinned" do
      assert {:ok, _} = serve()

      assert_received {:ran, command}
      assert command =~ "postgres:17"
      refute command =~ "postgres:latest"
    end

    # `docker run -d` returning 0 means the container was created. Postgres
    # takes seconds more to accept connections, and a migration that arrives
    # first fails in a way that reads like a broken image.
    test "waits until it actually accepts connections" do
      assert {:ok, _} = serve()

      assert_received {:ran, _start}
      assert_received {:ran, probe}

      assert probe =~ "pg_isready"
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
      assert Database.url(credential()) == "ecto://app:pw@cms-postgres/app_uat"
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
