defmodule CodeMySpecLocalWeb.HarnessSocket do
  @moduledoc """
  The **data-plane** socket the Pi harness connects to (`/harness_socket`).

  It is NOT the user chat — that lives on the server (`Conversations` + the
  operator inbox); cms bridges the two, relaying harness `agent_message`s up to
  the server (see `CodeMySpec.AgentHarness`).

  Auth: the harness presents the machine-local `CodeMySpec.AgentHarness.Secret` as
  the `token` param — not the user's server OAuth token (that never leaves the
  machine). The `LocalOnly` IP check is bypassable over a tunnel, so this secret
  is the real gate. Scope is then resolved from the working directory, mirroring
  `CodeMySpec.McpServers.Validators.validate_local_scope/1`. The Pi launcher sets
  `external_id` to `"pi:<cwd>"`, where `cwd` is the linked project's
  `local_path`; we strip the prefix and look the project up. An explicit
  `working_dir` param wins if provided. Connections that fail auth or don't
  resolve to a linked project are rejected.
  """

  use Phoenix.Socket
  require Logger

  alias CodeMySpec.AgentHarness.Secret
  alias CodeMySpec.Projects
  alias CodeMySpec.Users.Scope

  channel "harness:session:*", CodeMySpecLocalWeb.HarnessChannel

  @impl true
  def connect(params, socket, _connect_info) do
    external_id = params["external_id"]

    with :ok <- authenticate(params["token"]),
         {:ok, working_dir} <- working_dir(params, external_id),
         {:ok, project} <- Projects.get_project_by_local_path(working_dir),
         {:ok, scope} <- Scope.for_local_project(project) do
      {:ok,
       socket
       |> assign(:scope, scope)
       |> assign(:account_id, scope.active_account_id)
       |> assign(:external_id, external_id)}
    else
      other ->
        Logger.warning(
          "[HarnessSocket] connect refused external_id=#{inspect(external_id)}: #{inspect(other)}"
        )

        :error
    end
  end

  # The machine-local secret gates the socket. A deployment can opt out
  # (`harness_auth_required: false`) for a fully trusted, untunneled localhost.
  defp authenticate(token) do
    if Application.get_env(:code_my_spec, :harness_auth_required, true) do
      if Secret.valid?(token), do: :ok, else: {:error, :unauthorized}
    else
      :ok
    end
  end

  # Explicit param wins; otherwise derive from `external_id` = "pi:<cwd>".
  defp working_dir(%{"working_dir" => dir}, _ext) when is_binary(dir) and dir != "", do: {:ok, dir}
  defp working_dir(_params, "pi:" <> dir) when dir != "", do: {:ok, dir}
  defp working_dir(_params, _ext), do: {:error, :no_working_dir}

  @impl true
  def id(%{assigns: %{external_id: ext}}) when is_binary(ext), do: "harness_socket:#{ext}"
  def id(_socket), do: nil
end
