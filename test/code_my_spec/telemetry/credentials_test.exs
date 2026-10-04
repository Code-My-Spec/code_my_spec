defmodule CodeMySpec.Telemetry.CredentialsTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Provisioning.ClickHouse.Credentials

  test "publication encrypts owner credentials and preserves the scoped platform reader" do
    {:ok, directory} = Briefly.create(directory: true)
    environment = CodeMySpec.Environments.Environment.new(:local, directory)
    scope = %{full_scope_fixture() | environment: environment}
    {:ok, {public, private}} = CodeMySpec.Provisioning.Sops.generate_key()
    assert :ok = CodeMySpec.Provisioning.Sops.write_config(environment, %{"prod" => public})
    assert {:ok, _} = CodeMySpec.Provisioning.Steps.import_age_key(scope, "prod", private)
    assert {:ok, credentials} = Credentials.prepare(scope, "prod", "box-a")

    assert :ok = Credentials.publish(scope, "prod", "telemetry.example.com", credentials)

    assert {:ok, owner_values} =
             CodeMySpec.Provisioning.Sops.decrypt(environment, "prod", private)

    assert owner_values["CLICKHOUSE_URL"] == "https://telemetry.example.com"
    assert owner_values["CLICKHOUSE_USERNAME"] == credentials.owner.username
    assert owner_values["CLICKHOUSE_PASSWORD"] == credentials.owner.password

    assert {:ok, username} =
             ProjectSecrets.fetch_value(scope, "CLICKHOUSE_USERNAME", environment: "prod")

    assert {:ok, password} =
             ProjectSecrets.fetch_value(scope, "CLICKHOUSE_PASSWORD", environment: "prod")

    assert username == credentials.reader.username
    assert password == credentials.reader.password
    refute password == credentials.owner.password

    assert {:ok, ciphertext} =
             CodeMySpec.Environments.read_file(environment, "envs/prod.enc.env")

    assert ciphertext =~ "ENC["
    refute ciphertext =~ credentials.owner.password
    refute ciphertext =~ credentials.reader.password
    assert {:ok, ^credentials} = Credentials.prepare(scope, "prod", "box-a")
  end

  test "repeated setup preserves every credential" do
    scope = full_scope_fixture()
    assert {:ok, first} = Credentials.prepare(scope, "prod", "box-a")
    assert {:ok, second} = Credentials.prepare(scope, "prod", "box-a")
    assert first == second
    assert first.reader.password != first.owner.password
    assert first.writer.password != first.admin.password
  end

  test "environments on the same box share infrastructure credentials but have separate readers" do
    scope = full_scope_fixture()
    assert {:ok, prod} = Credentials.prepare(scope, "prod", "box-a")
    assert {:ok, uat} = Credentials.prepare(scope, "uat", "box-a")
    assert prod.admin == uat.admin
    assert prod.writer == uat.writer
    assert prod.owner == uat.owner
    refute prod.reader.username == uat.reader.username
    refute prod.reader.password == uat.reader.password
  end

  test "different boxes receive different privileged passwords" do
    scope = full_scope_fixture()
    assert {:ok, first} = Credentials.prepare(scope, "prod", "box-a")
    assert {:ok, second} = Credentials.prepare(scope, "uat", "box-b")
    refute first.admin.password == second.admin.password
    refute first.writer.password == second.writer.password
    refute first.owner.password == second.owner.password
  end

  test "preparation stores only the scoped reader password in the project environment" do
    scope = full_scope_fixture()
    assert {:ok, credentials} = Credentials.prepare(scope, "prod", "box-a")

    assert {:ok, password} =
             ProjectSecrets.fetch_value(scope, "CLICKHOUSE_PASSWORD", environment: "prod")

    assert password == credentials.reader.password

    assert {:error, :not_found} =
             ProjectSecrets.fetch_value(scope, "CLICKHOUSE_PASSWORD", environment: "uat")

    assert {:error, :not_found} =
             ProjectSecrets.fetch_value(scope, "CLICKHOUSE_URL", environment: "prod")
  end
end
