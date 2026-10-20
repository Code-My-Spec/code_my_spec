defmodule CodeMySpec.Workspaces.Runner do
  @moduledoc """
  Whatever actually runs an instance.

  It is also what a dev box is added from (story 1130): `dev_boxes/0` lists the
  runners that say who they are (`id/0`, `label/0`, `kind/0`) and what to show
  for the token of a box added from them (`instructions/1`).

  Today that is a devbox container on the local Docker daemon. The shared
  multi-tenant host is a second implementation of this same behaviour, which is
  the point of it being a behaviour. Configure with:

      config :code_my_spec, CodeMySpec.Workspaces, runner: MyRunner
  """

  @doc """
  Start an instance named `container_name`, publishing its app on `port`.

  `env` is what the instance needs to know about itself that it cannot work out
  from inside: which working copy it is, and the key it authenticates as. An
  instance with neither still starts — it just comes up as a directory rather
  than as a working copy somebody owns.
  """
  @callback start(
              container_name :: String.t(),
              app_name :: String.t(),
              port :: pos_integer(),
              env :: [{String.t(), String.t()}]
            ) :: :ok | {:error, term()}

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

  @doc """
  What the app on `port` is actually doing.

  `healthy?/1` answers "did anything reply", which is the right question while
  waiting for a boot and the wrong one afterwards: it was written to replace a
  TCP connect that succeeded before the app served, and any HTTP response
  counts, 500 included. So an app raising on every request reads as ready.

  `:serving` — answered, and not with a server error.
  `:erroring` — answered with 5xx. The instance is fine; the app is not.
  `:down` — nothing answered.
  """
  @callback serving(port :: pos_integer()) :: :serving | :erroring | :down

  @doc "Whether the instance is still alive at all — a dead container never becomes healthy."
  @callback alive?(container_name :: String.t()) :: boolean()

  @doc "Everything the instance has announced so far, for reading progress off."
  @callback logs(container_name :: String.t()) :: String.t()

  @callback stop(container_name :: String.t()) :: :ok

  @type section :: %{
          required(:key) => String.t(),
          required(:copy) => String.t(),
          required(:title) => String.t(),
          required(:body) => String.t()
        }

  @doc "As a dev box provider (story 1130): its id, as stored on the device and posted by the add form."
  @callback id() :: atom()

  @doc "As a dev box provider: what the person picks it by."
  @callback label() :: String.t()

  @doc "As a dev box provider: `:local` or `:cloud`, the kind of machine a box from it is."
  @callback kind() :: :local | :cloud

  @doc """
  As a dev box provider: what to show with the token of a box just added,
  sections each with a copy button. `context` carries the `:token` and this
  server's `:server_url`.
  """
  @callback instructions(context :: %{token: String.t(), server_url: String.t()}) :: [section()]

  @optional_callbacks id: 0, label: 0, kind: 0, instructions: 1

  @dev_boxes [__MODULE__.Local, __MODULE__.ClaudeCodeCloud]

  @doc "The runners a dev box can be added from."
  @spec dev_boxes() :: [module()]
  def dev_boxes, do: @dev_boxes

  @doc "The dev box runner for an id (atom or string), or nil."
  @spec dev_box(atom() | String.t() | nil) :: module() | nil
  def dev_box(id), do: Enum.find(@dev_boxes, &(to_string(&1.id()) == to_string(id)))

  @spec start(String.t(), String.t(), pos_integer()) :: :ok | {:error, term()}
  def start(container_name, app_name, port, env \\ []),
    do: impl().start(container_name, app_name, port, env)

  @spec url(String.t(), pos_integer()) :: String.t()
  def url(container_name, port), do: impl().url(container_name, port)

  @spec serving(pos_integer()) :: :serving | :erroring | :down
  def serving(port), do: impl().serving(port)

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
