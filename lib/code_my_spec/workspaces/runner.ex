defmodule CodeMySpec.Workspaces.Runner do
  @moduledoc """
  Whatever actually runs an instance.

  Today that is a devbox container on the local Docker daemon. The shared
  multi-tenant host is a second implementation of this same behaviour, which is
  the point of it being a behaviour. Configure with:

      config :code_my_spec, CodeMySpec.Workspaces, runner: MyRunner
  """

  @doc "Start an instance named `container_name`, publishing its app on `port`."
  @callback start(container_name :: String.t(), app_name :: String.t(), port :: pos_integer()) ::
              :ok | {:error, term()}

  @doc """
  Where this instance can be reached from a browser.

  How an instance is addressed is the runner's business, not the schema's. The
  local runner publishes a port on the loopback; a hosted one puts each
  instance on its own subdomain, which is not a detail — a preview shown in an
  iframe needs a same-site origin or Safari blocks the session cookie, and the
  target's CSRF token and LiveView connect go with it.
  """
  @callback url(container_name :: String.t(), port :: pos_integer()) :: String.t()

  @doc "Whether the instance is answering on `port` yet."
  @callback healthy?(port :: pos_integer()) :: boolean()

  @doc "Whether the instance is still alive at all — a dead container never becomes healthy."
  @callback alive?(container_name :: String.t()) :: boolean()

  @doc "Everything the instance has announced so far, for reading progress off."
  @callback logs(container_name :: String.t()) :: String.t()

  @callback stop(container_name :: String.t()) :: :ok

  @spec start(String.t(), String.t(), pos_integer()) :: :ok | {:error, term()}
  def start(container_name, app_name, port), do: impl().start(container_name, app_name, port)

  @spec url(String.t(), pos_integer()) :: String.t()
  def url(container_name, port), do: impl().url(container_name, port)

  @spec logs(String.t()) :: String.t()
  def logs(container_name), do: impl().logs(container_name)

  @spec healthy?(pos_integer()) :: boolean()
  def healthy?(port), do: impl().healthy?(port)

  @spec alive?(String.t()) :: boolean()
  def alive?(container_name), do: impl().alive?(container_name)

  @spec stop(String.t()) :: :ok
  def stop(container_name), do: impl().stop(container_name)

  defp impl do
    :code_my_spec
    |> Application.get_env(CodeMySpec.Workspaces, [])
    |> Keyword.get(:runner, CodeMySpec.Workspaces.Runner.Docker)
  end
end
