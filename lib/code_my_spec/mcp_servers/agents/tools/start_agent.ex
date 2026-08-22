defmodule CodeMySpec.McpServers.Agents.Tools.StartAgent do
  @moduledoc """
  Start a coding agent on a working copy, on one of the account's connected
  providers.

  The provider is required rather than defaulted. A machine-wide default
  answers correctly right until two callers want different things, and then
  quietly spends the wrong subscription for one of them — which nobody notices
  until a quota or a bill does.

  If the named provider has no usable credential this refuses and says which
  one, rather than starting an agent that fails on its first model call.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Agents
  alias CodeMySpec.McpServers.Agents.AgentsMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :provider, :string,
      required: true,
      doc: "Provider to run on, e.g. openai-codex, anthropic, zai"

    field :engine, :string, doc: "Agent engine: pi (default) or claude_code"

    field :working_copy, :string,
      doc: "Root of the working copy to run in. Defaults to the caller's own."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         {:ok, agent} <- Agents.start_agent(scope, attrs(params)) do
      {:reply, AgentsMapper.started(agent), frame}
    else
      {:error, reason} -> {:reply, AgentsMapper.error(reason, provider(params)), frame}
    end
  end

  defp attrs(params) do
    %{
      provider: provider(params),
      engine: engine(params),
      working_copy: params["working_copy"] || params[:working_copy]
    }
  end

  defp provider(params), do: params["provider"] || params[:provider]

  defp engine(params) do
    params["engine"] || params[:engine]
    |> to_engine()
  end

  defp to_engine("claude_code"), do: :claude_code
  defp to_engine(_other), do: :pi
end
