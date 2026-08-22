defmodule CodeMySpec.Agents.PiConfig do
  @moduledoc """
  Where a Pi agent's configuration lives, and what goes in it.

  Pi reads its whole configuration from one directory — models, settings,
  extensions and `auth.json` together — named by `PI_CODING_AGENT_DIR` and
  defaulting to `~/.pi/agent`. That default is a single directory per machine,
  which is exactly what we cannot use.

  ## One directory per working copy

  Two independent reasons, and either alone would be enough.

  Tenancy: the cloud host is multi-tenant. A shared `auth.json` is one tenant's
  ChatGPT subscription sitting at a path another tenant's agent can read — and
  an agent is a process that reads files for a living and can be asked to read
  one. Per-copy configuration is not a preference about isolation; it *is* the
  isolation, and it is the same criterion story 986's shared host is built to.

  Outside the copy: a working copy is a git repository whose purpose is to be
  committed. `agent.sh` commits with `git add -A` on a clean exit. A credential
  written into the tree is therefore not at risk of leaking — it has a
  supervisor scheduled to carry it out.

  So the directory is keyed by account and agent, and rooted outside every
  working copy.
  """

  alias CodeMySpec.Agents.Agent

  @doc """
  The configuration directory for one agent.

  Keyed by account first so a tenant's agents cluster under one path that can be
  permissioned as a unit, and by agent id so two agents on one copy do not share
  a credential file they would then race to refresh.
  """
  @spec dir(Ecto.UUID.t(), Ecto.UUID.t()) :: String.t()
  def dir(account_id, agent_id) when is_binary(account_id) and is_binary(agent_id) do
    Path.join([root(), "accounts", account_id, "agents", agent_id])
  end

  @doc """
  Root of every minted configuration directory.

  Overridable so a test does not write into the operator's real Pi setup, and so
  a container can point it at a mounted volume. Never inside a working copy.
  """
  @spec root() :: String.t()
  def root do
    Application.get_env(:code_my_spec, :pi_config_root) ||
      Path.join([System.tmp_dir!(), "codemyspec", "pi"])
  end

  @doc """
  Writes the configuration Pi needs to start, and returns the directory.

  `auth.json` is written 0600 because that is the mode Pi itself uses, and on a
  shared host the file mode is the last line rather than the first.
  """
  @spec mint(Agent.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def mint(%Agent{account_id: account_id, id: id, provider: provider}, credential) do
    dir = dir(account_id, id)

    with :ok <- File.mkdir_p(dir),
         :ok <- write_auth(dir, provider, credential) do
      {:ok, dir}
    end
  end

  defp write_auth(dir, provider, credential) do
    path = Path.join(dir, "auth.json")

    with :ok <- File.write(path, Jason.encode!(%{provider => credential}, pretty: true)) do
      File.chmod(path, 0o600)
    end
  end
end
