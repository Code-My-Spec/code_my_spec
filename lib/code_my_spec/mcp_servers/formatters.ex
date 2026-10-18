defmodule CodeMySpec.McpServers.Formatters do
  @moduledoc """
  Changeset errors for the MCP components not yet moved into their domains;
  the text is `CodeMySpec.Tools.changeset_errors/1`'s, so both read the same.
  """

  defdelegate format_changeset_errors(changeset), to: CodeMySpec.Tools, as: :changeset_errors
  defdelegate extract_errors(changeset), to: CodeMySpec.Tools, as: :changeset_error_map
end
