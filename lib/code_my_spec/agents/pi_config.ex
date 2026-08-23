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

  Four files, and only one of them is the credential.

  A credential alone gets you an agent that runs perfectly and cannot be seen.
  Pi ships no MCP of its own — a deliberate choice by its author — so without
  `settings.json` naming the adapter extension and `mcp.json` naming this
  harness, the agent never joins `harness:session:pi:<cwd>`, never appears in
  Presence, never relays a turn, and cannot be talked to. It is invisible to
  every surface that exists to watch it.

  That gap is what story 957 found: "ready to run Pi" was being checked by
  asserting a config directory exists, which is true of a directory holding one
  file.

  `auth.json` is 0600 because that is the mode Pi uses, and on a shared host the
  file mode is the last line rather than the first.
  """
  @spec mint(Agent.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def mint(%Agent{account_id: account_id, id: id, provider: provider} = agent, credential) do
    dir = dir(account_id, id)

    with :ok <- File.mkdir_p(dir),
         :ok <- write_auth(dir, provider, credential),
         :ok <- write_json(dir, "settings.json", settings()),
         :ok <- write_json(dir, "mcp.json", mcp(agent)),
         :ok <- write_models(dir, provider) do
      {:ok, dir}
    end
  end

  defp write_auth(dir, provider, credential) do
    path = Path.join(dir, "auth.json")

    with :ok <- File.write(path, Jason.encode!(%{provider => credential}, pretty: true)) do
      File.chmod(path, 0o600)
    end
  end

  defp write_json(dir, name, contents),
    do: dir |> Path.join(name) |> File.write(Jason.encode!(contents, pretty: true))

  # `pi-mcp-adapter` because Pi has no MCP and this is what gives it any; the
  # CodeMySpec extension because that is what joins the harness and relays turns.
  # Subagents are deliberately absent — nothing here delegates yet, and an
  # extension that is not used is an extension that can still fail to load.
  defp settings do
    %{
      "extensions" => [
        "npm:pi-mcp-adapter",
        "npm:@codemyspec/pi-codemyspec"
      ]
    }
  end

  # Addressed to this working copy's harness, not to whatever the machine
  # happens to be serving. A relay pointed at the wrong harness reports one
  # copy's work against another, which reads as the agent doing something it
  # never did.
  #
  # `directTools` is not a preference. The adapter hides every tool behind one
  # `mcp()` proxy by default, and the server's PreToolUse enrichment matches on
  # real tool names — so hidden tools arrive unenriched and the matcher silently
  # does nothing.
  defp mcp(%Agent{harness_id: harness_id}) do
    %{
      "mcpServers" => %{
        "plugin_codemyspec_local" => %{
          "command" => "cms-mcp-relay",
          "env" => %{
            "CMS_MCP_BASE_URL" => base_url(),
            "CMS_HARNESS_ID" => harness_id
          },
          "lifecycle" => "eager",
          "directTools" => true
        }
      },
      "settings" => %{"toolPrefix" => "server", "outputGuard" => true}
    }
  end

  # Only providers Pi does not already know need a catalog entry. `openai-codex`
  # and `anthropic` are built in; writing a models.json for them would override
  # a catalog Pi maintains and we do not.
  defp write_models(dir, "zai"),
    do:
      write_json(dir, "models.json", %{
        "providers" => %{
          "zai" => %{
            # The coding path, not the pay-as-you-go one: the same key works on
            # both, and only this one spends subscription quota rather than
            # credits.
            "baseUrl" => "https://api.z.ai/api/coding/paas/v4",
            "api" => "openai-completions",
            "apiKey" => "$ZAI_API_KEY"
          }
        }
      })

  defp write_models(_dir, _provider), do: :ok

  @doc """
  What `mint/2` writes, so a caller can say a copy is ready rather than assert a
  directory exists.

  The distinction is the whole of story 957's finding: a config directory
  containing only `auth.json` satisfies "a directory is there" and produces an
  agent nothing can see.
  """
  @spec files(String.t()) :: [String.t()]
  def files("zai"), do: ["auth.json", "settings.json", "mcp.json", "models.json"]
  def files(_provider), do: ["auth.json", "settings.json", "mcp.json"]

  @doc """
  Where a minted agent's relay points.

  Overridable because the local server is on 4003 as the published binary and
  4004 in a dev checkout, and an agent pointed at the wrong one fails in a way
  that names neither port.
  """
  @spec base_url() :: String.t()
  def base_url,
    do: Application.get_env(:code_my_spec, :pi_mcp_base_url, "http://localhost:4003")
end
