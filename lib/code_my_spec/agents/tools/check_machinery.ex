defmodule CodeMySpec.Agents.Tools.CheckMachinery do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.Agents.Tools.MachineryResponses, as: MachineryMapper

  @impl true
  def name, do: "check_machinery"

  @impl true
  def description do
    """
    Whether the things your agents depend on are working: the harness, the tool
    surface, the preview, the analyzers and the machine itself.

    Ask it when an agent misbehaves, before restarting anything. A fault every
    agent shares is one fault underneath them and restarting them will not reach
    it; a fault one agent has while its neighbours work is that agent's.

    Healthy is reported as well as broken, so you can rule the machinery out.
    """
  end

  @impl true
  def params do
    %{}
  end

  @impl true
  def call(_params, context) do
    case CodeMySpec.Tools.project_scope(context) do
      {:ok, scope} -> MachineryMapper.report(MainAgent.check_machinery(scope))
      {:error, reason} -> MachineryMapper.error(reason)
    end
  end
end
