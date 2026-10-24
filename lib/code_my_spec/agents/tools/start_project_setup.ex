defmodule CodeMySpec.Agents.Tools.StartProjectSetup do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  @impl true
  def name, do: "start_project_setup"

  @impl true
  def description do
    """
    Hand development environment setup to Main after the user agrees on a brief synopsis,
    new/existing starting point, source for existing code, and development destination.
    Read and save these with get_project_onboarding/update_project_onboarding first.
    Starts Main independently of a checkout on desktop, or uses an existing Main on a
    connected execution host. Repeated calls reuse the same agent and setup request.
    Success unlocks the story interview; it means setup was handed off, not completed.
    If unavailable, explain the blocker and resolve the execution host before interviewing stories.
    """
  end

  @impl true
  def params, do: %{}

  @impl true
  def call(params, context) do
    case script_result(params, context) do
      {:ok, data} -> {:ok, Jason.encode!(data)}
      error -> error
    end
  end

  @impl true
  def script_result(_params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, _project, agent} <- CodeMySpec.Agents.start_project_setup(scope) do
      {:ok,
       %{
         phase: :stories,
         setup_agent_id: agent.id,
         message: "Main has the setup request. Begin the story interview while setup proceeds."
       }}
    else
      {:error, :incomplete_onboarding} ->
        {:error,
         "First save the brief synopsis, starting point, source for existing code, and development destination. Do not begin the story interview yet."}

      {:error, :no_execution_host} ->
        {:error,
         "No execution host is available for Main. Connect a development environment before handing off setup."}

      {:error, :agent_off} ->
        {:error, "Main is turned off. Turn it on before handing off setup."}

      {:error, reason} ->
        CodeMySpec.Tools.error(reason)
    end
  end
end
