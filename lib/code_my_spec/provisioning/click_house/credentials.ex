defmodule CodeMySpec.Provisioning.ClickHouse.Credentials do
  @moduledoc false

  alias CodeMySpec.{AccountSecrets, ProjectSecrets}
  alias CodeMySpec.Provisioning.Steps

  def prepare(scope, environment, box_id) do
    box = suffix(box_id)
    project = suffix({scope.active_project_id, environment})

    with {:ok, admin} <- account_credential(scope, box, "ADMIN", "cms_admin"),
         {:ok, writer} <- account_credential(scope, box, "WRITER", "cms_writer"),
         {:ok, owner} <- account_credential(scope, box, "OWNER", "cms_owner"),
         {:ok, password} <-
           mint(ProjectSecrets, scope, "CLICKHOUSE_PASSWORD", environment: environment) do
      {:ok,
       %{
         admin: admin,
         writer: writer,
         owner: owner,
         reader: %{username: "cms_project_#{project}", password: password}
       }}
    end
  end

  def publish(scope, environment, host, credentials) do
    url = "https://#{host}"

    with :ok <- store_owner(scope, environment, url, credentials.owner) do
      store_platform(scope, environment, url, credentials.reader)
    end
  end

  defp store_owner(scope, environment, url, owner) do
    values = [
      {"CLICKHOUSE_URL", url},
      {"CLICKHOUSE_USERNAME", owner.username},
      {"CLICKHOUSE_PASSWORD", owner.password}
    ]

    store(values, fn key, value -> Steps.put_secret(scope, environment, key, value) end)
  end

  defp store_platform(scope, environment, url, reader) do
    values = [
      {"CLICKHOUSE_URL", url},
      {"CLICKHOUSE_USERNAME", reader.username},
      {"CLICKHOUSE_PASSWORD", reader.password}
    ]

    store(values, fn key, value ->
      ProjectSecrets.put_value(scope, key, value, environment: environment)
    end)
  end

  defp store(values, put) do
    Enum.reduce_while(values, :ok, fn {key, value}, :ok ->
      case put.(key, value) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} -> {:halt, {:error, "could not persist telemetry credential #{key}"}}
      end
    end)
  end

  defp account_credential(scope, box, role, username) do
    with {:ok, password} <- mint(AccountSecrets, scope, "CLICKHOUSE_#{box}_#{role}_PASSWORD", []) do
      {:ok, %{username: username, password: password}}
    end
  end

  defp mint(store, scope, key, opts) do
    case store.fetch_value(scope, key, opts) do
      {:ok, password} when is_binary(password) and password != "" ->
        {:ok, password}

      {:error, :not_found} ->
        password = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

        case store.put_value(scope, key, password, opts) do
          {:ok, _} -> {:ok, password}
          {:error, _} -> {:error, "could not persist telemetry credential #{key}"}
        end

      _ ->
        {:error, "could not load telemetry credential #{key}"}
    end
  end

  defp suffix(value) do
    :crypto.hash(:sha256, :erlang.term_to_binary(value))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 24)
  end
end
