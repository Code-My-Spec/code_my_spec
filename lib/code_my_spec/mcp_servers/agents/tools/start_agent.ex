defmodule CodeMySpec.McpServers.Agents.Tools.StartAgent do
  @moduledoc """
  Start an agent of a given type on a working copy.

  The type decides the provider and model: an account says once what QA runs on
  and what its coder runs on, and this looks that up. Naming a provider
  explicitly still wins, for the caller that genuinely wants a particular one.

  The old shape required a provider on every call. That was right while there
  was nowhere to record the answer — a machine-wide default answers correctly
  right until two callers want different things, and then quietly spends the
  wrong subscription for one of them. Story 983 gave it somewhere to live, and
  per-type is the grain that was actually wanted.

  If the resolved provider has no usable credential this refuses and says which
  one, rather than starting an agent that fails on its first model call.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Agents
  alias CodeMySpec.McpServers.Agents.AgentsMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :role, :string, doc: "Agent type: main, product, coding or qa. Defaults to main."

    field :provider, :string,
      doc: "Override the provider this type would use, e.g. openai-codex, anthropic, zai"

    field :engine, :string, doc: "Agent engine: pi (default) or claude_code"

    field :working_copy, :string,
      doc: "Root of the working copy to run in. Defaults to the caller's own."

    field :working_copy_id, :string,
      doc:
        "Id of the working copy to run in, from list_working_copies. Takes priority over working_copy when both are given."
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
      role: params["role"] || params[:role] || "main",
      provider: provider(params),
      engine: engine(params),
      working_copy: params["working_copy"] || params[:working_copy],
      working_copy_id: params["working_copy_id"] || params[:working_copy_id]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp provider(params), do: params["provider"] || params[:provider]

  defp engine(params) do
    params["engine"] ||
      params[:engine]
      |> to_engine()
  end

  defp to_engine("claude_code"), do: :claude_code
  defp to_engine(_other), do: :pi
end
