defmodule CmsHarness.Setup.Database do
  @moduledoc "Prepares access to the local development PostgreSQL server without changing authentication."

  alias CmsHarness.Setup.{Command, Platform}

  @doc """
  Verifies the current OS user's PostgreSQL role on a local Unix socket.

  On Linux, root can create its missing login/createdb role through the local
  postgres OS account. Existing roles and authentication settings are never
  modified. Commands and their results are returned for the setup transcript.
  The runner and platform options allow isolated tests without a database.
  """
  def prepare(cwd, opts \\ []) do
    platform = Keyword.get_lazy(opts, :platform, &Platform.detect/0)

    state = %{
      cwd: cwd,
      runner: Keyword.get(opts, :runner, &Command.run/3),
      commands: [],
      runuser: Keyword.get_lazy(opts, :runuser_command, &runuser_command/0),
      socket: Keyword.get(opts, :socket_directory, socket_directory(platform))
    }

    if platform.os in [:linux, :darwin] and is_binary(state.socket) and
         Path.type(state.socket) == :absolute do
      prepare_user(state, platform)
    else
      failure(
        state,
        "Automatic PostgreSQL role preparation requires a local Unix socket. Configure local development database access on this platform, then retry the prerequisite checks."
      )
    end
  end

  defp prepare_user(state, platform) do
    {identity, state} = run(state, "id", ["-un"])
    username = String.trim(identity.output)

    if Command.successful?(identity) and
         Regex.match?(~r/\A[a-zA-Z_][a-zA-Z0-9_.-]*\$?\z/, username) do
      state = Map.put(state, :username, username)

      {probe, state} =
        run(state, "psql", connection_args(state, username) ++ ["-At", "-c", "SELECT 1"])

      cond do
        Command.successful?(probe) -> success(state, false)
        platform.os == :linux -> prepare_missing_role(state)
        true -> unavailable(state)
      end
    else
      failure(
        state,
        "Could not determine a supported current OS username; configure local PostgreSQL access and retry."
      )
    end
  end

  defp prepare_missing_role(state) do
    {identity, state} = run(state, "id", ["-u"])

    if Command.successful?(identity) and String.trim(identity.output) == "0" do
      query = "SELECT 1 FROM pg_roles WHERE rolname = '#{state.username}'"

      args =
        ["-u", "postgres", "--", "psql"] ++
          connection_args(state, "postgres") ++ ["-At", "-c", query]

      {lookup, state} = run(state, state.runuser, args)

      if Command.successful?(lookup) and String.trim(lookup.output) == "" do
        create_role(state)
      else
        unavailable(state)
      end
    else
      unavailable(state)
    end
  end

  defp create_role(state) do
    args = [
      "-u",
      "postgres",
      "--",
      "createuser",
      "--no-password",
      "--host=#{state.socket}",
      "--port=5432",
      "--username=postgres",
      "--login",
      "--createdb",
      "--",
      state.username
    ]

    {created, state} = run(state, state.runuser, args)

    if Command.successful?(created) do
      {probe, state} =
        run(state, "psql", connection_args(state, state.username) ++ ["-At", "-c", "SELECT 1"])

      if Command.successful?(probe), do: success(state, true), else: unavailable(state)
    else
      failure(
        state,
        "Could not create the local PostgreSQL role for #{state.username}. Inspect the recorded createuser result, ensure the local server is running, and retry. No authentication settings were changed."
      )
    end
  end

  defp connection_args(state, username) do
    [
      "-X",
      "--no-password",
      "--host=#{state.socket}",
      "--port=5432",
      "--username=#{username}",
      "--dbname=postgres",
      "-v",
      "ON_ERROR_STOP=1"
    ]
  end

  defp run(state, command, args) do
    result = state.runner.(state.cwd, command, args)
    {result, %{state | commands: state.commands ++ [result]}}
  end

  defp success(state, created?) do
    {:ok, %{commands: state.commands, username: state.username, created?: created?}}
  end

  defp unavailable(state) do
    failure(
      state,
      "Local PostgreSQL access for #{state.username} is unavailable. Ensure the local server is running and ask its administrator to provide a login/createdb role for this OS user. Automatic creation is limited to a missing role when running as Linux root; existing roles, passwords and authentication settings are left unchanged. Retry prerequisite checks after fixing access."
    )
  end

  defp failure(state, message),
    do: {:error, %{commands: state.commands, username: Map.get(state, :username), error: message}}

  defp runuser_command do
    Enum.find(["/usr/sbin/runuser", "/sbin/runuser"], &File.regular?/1) || "runuser"
  end

  defp socket_directory(%Platform{os: :linux}), do: "/var/run/postgresql"
  defp socket_directory(%Platform{os: :darwin}), do: "/tmp"
  defp socket_directory(_platform), do: nil
end
