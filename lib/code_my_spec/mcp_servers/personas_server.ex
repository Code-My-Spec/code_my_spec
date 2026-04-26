defmodule CodeMySpec.McpServers.PersonasServer do
  @moduledoc false

  use Anubis.Server,
    name: "personas-server",
    version: "1.0.0",
    capabilities: [:tools]

  component(CodeMySpec.McpServers.Personas.Tools.CreatePersona)
  component(CodeMySpec.McpServers.Personas.Tools.UpdatePersona)
  component(CodeMySpec.McpServers.Personas.Tools.DeletePersona)
  component(CodeMySpec.McpServers.Personas.Tools.LinkPersonaToStory)
  component(CodeMySpec.McpServers.Personas.Tools.UnlinkPersonaFromStory)
  component(CodeMySpec.McpServers.Personas.Tools.ListPersonas)
  component(CodeMySpec.McpServers.Personas.Tools.GetPersona)
end
