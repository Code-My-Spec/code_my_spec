defmodule CodeMySpec.Personas.Tools.CreatePersona do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Personas
  alias CodeMySpec.Personas.Tools

  @impl true
  def name, do: "create_persona"

  @impl true
  def description do
    """
    Creates a project-scoped persona. Identity + metadata only — research text
    belongs on disk at `.code_my_spec/personas/<slug>/`.
    """
  end

  @impl true
  def params do
    %{
      slug:
        {:required,
         {:meta, :string,
          [
            description:
              "URL-safe identifier, lowercase alphanumeric with hyphens or underscores (e.g., 'founder', 'agency_pm'). Unique per project."
          ]}},
      name:
        {:required,
         {:meta, :string, [description: "Display name (e.g., 'Founder', 'Agency PM')."]}},
      headline:
        {:meta, :string,
         [
           description:
             "One-line summary for UI cards (e.g., 'Solo founder shipping a product without hiring')."
         ]},
      persona_type:
        {:meta, :string,
         [
           description:
             "Evidence tier: 'proto' (hypothesis from desk research), 'qualitative' (5–30 user interviews), " <>
               "or 'statistical' (large survey + cluster analysis). Default: 'proto'. " <>
               "Agent-produced personas from desk research should stay 'proto' until validated with real users."
         ]}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- Tools.scope(context),
         {:ok, persona} <- Personas.create_persona(scope, params) do
      {:ok, Tools.persona_text(persona)}
    else
      {:error, reason} -> Tools.error(reason)
    end
  end
end
