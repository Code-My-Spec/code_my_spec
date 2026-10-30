defmodule CodeMySpec.Qa.Tools.RemoveQaEvidence do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Qa

  @impl true
  def name, do: "remove_qa_evidence"

  @impl true
  def description do
    "Remove wrongly attached files from one QA attempt. Records who, when, and why; leaves its verdict and scenarios intact. Use list_qa_attempts to find the attempt and filenames."
  end

  @impl true
  def params do
    %{
      attempt_id: {:required, :string},
      filenames: {:required, {:list, :string}},
      reason: {:required, :string}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, attempt} <-
           Qa.remove_qa_evidence(scope, params.attempt_id, params.filenames, params.reason) do
      {:ok,
       "QA evidence corrected. attempt_id: #{attempt.id}; removed: #{Enum.join(params.filenames, ", ")}; status: #{attempt.status}; reason: #{String.trim(params.reason)}"}
    else
      {:error, :attempt_not_found} ->
        {:error, "QA attempt not found in this project."}

      {:error, :evidence_not_found} ->
        {:error, "One or more filenames are not attached to this attempt."}

      {:error, :invalid_correction} ->
        {:error, "Provide at least one filename and a non-empty reason."}

      {:error, reason} ->
        {:error, "remove_qa_evidence failed: #{inspect(reason)}"}
    end
  end
end
