defmodule CodeMySpec.Projects.Tools.UpdateProjectOnboarding do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool
  alias CodeMySpec.Projects.{Onboarding, Tools}

  @impl true
  def name, do: "update_project_onboarding"
  @impl true
  def description do
    """
    Record the user's agreed onboarding choices on the connected project, without a working copy.
    Omitted fields are preserved. Read get_project_onboarding first. If sources is supplied, it
    replaces the entire list: retain existing source IDs and entries you want to keep; [] clears it.
    Use available_devices from get_project_onboarding for local device IDs; paths are absolute on
    that device, not this agent's scratch directory. Do not invent choices or assessment results.
    Saving updates the cockpit Project panel. It does not inspect, clone, provision, or modify code.
    """
  end

  @impl true
  def params do
    %{
      onboarding:
        {:meta,
         %{
           description: :string,
           starting_point: {:enum, ~w(new existing)},
           destination: {:enum, ~w(local cloud external)}
         }, [description: "Only the agreed fields to change; omitted fields remain unchanged."]},
      sources:
        {:meta,
         {:list,
          %{
            id: :string,
            kind: {:required, {:enum, ~w(github local)}},
            repository_url: :string,
            ref: :string,
            device_id: :string,
            path: :string
          }},
         [
           description:
             "Optional complete replacement source list. GitHub requires repository_url; local requires device_id and path."
         ]}
    }
  end

  @impl true
  def call(params, context), do: params |> script_result(context) |> Tools.text()
  @impl true
  def script_result(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, project} <- Onboarding.save(scope, params) do
      {:ok, Tools.snapshot(project, scope)}
    else
      {:error, reason} -> Tools.error(reason)
    end
  end
end
