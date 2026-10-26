defmodule CodeMySpec.AgentAttachments.Tools do
  @moduledoc "Explicit working-copy attachments and their remote operations."
  use Boundary,
    top_level?: true,
    deps: [CodeMySpec.AgentAttachments, CodeMySpec.Agents, CodeMySpec.Tools]

  alias CodeMySpec.Agents
  alias CodeMySpec.Tools

  def all do
    [
      __MODULE__.ConnectWorkingCopy,
      __MODULE__.DisconnectWorkingCopy,
      __MODULE__.ListWorkingCopyAttachments,
      __MODULE__.WorkInCopy
    ]
  end

  def caller(context, _params) do
    with {:ok, scope} <- Tools.project_scope(context) do
      id =
        context[:agent_id] ||
          Agents.terminal_agent_id(scope, context[:session_id])

      if is_binary(id), do: {:ok, scope, id}, else: {:error, :agent_required}
    end
  end

  def render({:ok, value}), do: {:ok, Jason.encode!(value)}
  def render(:ok), do: {:ok, "ok"}

  def render({:error, :attachment_not_connected}),
    do:
      {:error,
       "This attachment is not connected (the device may have reconnected since it was lost). " <>
         "Call connect_working_copy with the same working_copy_id to reconnect -- it is " <>
         "idempotent and returns this same attachment id."}

  def render({:error, reason}), do: Tools.error(reason)

  def row(attachment) do
    %{
      "id" => attachment.id,
      "agent_id" => attachment.agent_id,
      "working_copy_id" => attachment.working_copy_id
    }
  end
end
