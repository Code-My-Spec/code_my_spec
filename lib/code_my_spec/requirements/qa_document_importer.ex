defmodule CodeMySpec.Requirements.QaDocumentImporter do
  @moduledoc "Imports legacy QA documents and refreshes the requirement graph."

  alias CodeMySpec.Qa.DocumentImporter
  alias CodeMySpec.Requirements

  def import(scope, env) do
    with {:ok, report} <- DocumentImporter.import(scope, env) do
      if Enum.any?(report, &(&1.status == :imported)) do
        Requirements.recompute(scope)
      end

      {:ok, report}
    end
  end
end
