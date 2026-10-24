defmodule CodeMySpec.AgentAttachments.Tools.DisconnectWorkingCopy do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool
  alias CodeMySpec.AgentAttachments
  alias CodeMySpec.AgentAttachments.Tools

  @impl true
  def name, do: "disconnect_working_copy"
  @impl true
  def description do
    "Disconnect Main's attachment, cancelling pending work and terminating its owned commands " <>
      "and execution sessions. Does not delete the copy, stop independent Coding/QA agents, " <>
      "or affect other attachments. No work is saved for recovery."
  end

  @impl true
  def params do
    %{
      attachment_id: {:required, :string}
    }
  end

  @impl true
  def call(params, context), do: params |> script_result(context) |> Tools.render()
  @impl true
  def script_result(params, context) do
    with {:ok, scope, agent_id} <- Tools.caller(context, params),
         :ok <- AgentAttachments.disconnect(scope, agent_id, params.attachment_id) do
      {:ok, %{"disconnected" => true, "attachment_id" => params.attachment_id}}
    end
  end
end
