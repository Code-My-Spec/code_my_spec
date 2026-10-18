defmodule CmsHarness.Agents.Inbound do
  @moduledoc """
  Whether a terminal Claude Code session takes what we write to its inbox
  socket (story 1123), read from the settings files on this machine.

  Claude Code's `crossSessionInbound` is `accept`, `hold` or `refuse`.
  Managed settings and the repository's own settings may only tighten it; a
  person's local or user setting decides otherwise. Unset, a message is taken
  unless the session bypasses permission prompts, where one that attests no
  permission mode — ours do not — is held. An unrecognised value holds.

  A session that would hold or refuse is told through its stop hook instead,
  and is told why.
  """

  @type verdict :: :accept | {:held, String.t()} | {:refused, String.t()}

  @doc """
  The verdict for a session in the working copy at `root`, running in
  `permission_mode` (as its SessionStart reports it). `files` overrides where
  each settings layer is read from.
  """
  @spec verdict(String.t(), String.t() | nil, [{atom(), String.t()}] | nil) :: verdict()
  def verdict(root, permission_mode, files \\ nil) do
    values =
      for {layer, path} <- files || files(root), value = setting(path), do: {layer, path, value}

    case tightest(values) || personal(values) do
      nil ->
        unset(permission_mode)

      {path, "accept"} when is_binary(path) ->
        :accept

      {path, "refuse"} ->
        {:refused, "crossSessionInbound is \"refuse\" in #{path}"}

      {path, "hold"} ->
        {:held, "crossSessionInbound is \"hold\" in #{path}"}

      {path, other} ->
        {:held, "crossSessionInbound has the unrecognised value #{inspect(other)} in #{path}"}
    end
  end

  # Managed policy and the repository can tighten, never loosen.
  defp tightest(values) do
    Enum.find_value(values, fn
      {layer, path, value} when layer in [:managed, :project] and value != "accept" ->
        {path, value}

      _ ->
        nil
    end)
  end

  # Local over user: the person's own choice.
  defp personal(values) do
    Enum.find_value([:local, :user], fn layer ->
      Enum.find_value(values, fn
        {^layer, path, value} -> {path, value}
        _ -> nil
      end)
    end)
  end

  defp unset("bypassPermissions"),
    do:
      {:held,
       "this session bypasses permission prompts, so Claude Code holds messages that do not " <>
         "attest a permission mode; set crossSessionInbound to \"accept\" in your user settings"}

  defp unset(_mode), do: :accept

  defp setting(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"crossSessionInbound" => value}} when is_binary(value) <- Jason.decode(body) do
      value
    else
      _ -> nil
    end
  end

  defp files(root) do
    config = System.get_env("CLAUDE_CONFIG_DIR") || Path.expand("~/.claude")

    [
      managed: managed_path(),
      project: Path.join(root, ".claude/settings.json"),
      local: Path.join(root, ".claude/settings.local.json"),
      user: Path.join(config, "settings.json")
    ]
  end

  defp managed_path do
    case :os.type() do
      {:unix, :darwin} -> "/Library/Application Support/ClaudeCode/managed-settings.json"
      {:win32, _} -> "C:\\ProgramData\\ClaudeCode\\managed-settings.json"
      _ -> "/etc/claude-code/managed-settings.json"
    end
  end
end
