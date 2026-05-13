defmodule CodeMySpec.McpServers.Personas.Tools.CreatePersona do
  @moduledoc """
  Creates a project-scoped persona. Identity + metadata only — research text
  belongs on disk at `.code_my_spec/personas/<slug>/`.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.McpServers.Personas.PersonasMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Personas

  schema do
    field :slug, :string,
      required: true,
      doc:
        "URL-safe identifier, lowercase alphanumeric with hyphens or underscores (e.g., 'founder', 'agency_pm'). Unique per project."

    field :name, :string, required: true, doc: "Display name (e.g., 'Founder', 'Agency PM')."

    field :headline, :string,
      doc: "One-line summary for UI cards (e.g., 'Solo founder shipping a product without hiring')."

    field :persona_type, :string,
      doc:
        "Evidence tier: 'proto' (hypothesis from desk research), 'qualitative' (5–30 user interviews), " <>
          "or 'statistical' (large survey + cluster analysis). Default: 'proto'. " <>
          "Agent-produced personas from desk research should stay 'proto' until validated with real users."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, persona} <- Personas.create_persona(scope, params) do
      {:reply, PersonasMapper.persona_response(persona), frame}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:reply, PersonasMapper.validation_error(changeset), frame}

      {:error, reason} ->
        {:reply, PersonasMapper.error(reason), frame}
    end
  end
end
