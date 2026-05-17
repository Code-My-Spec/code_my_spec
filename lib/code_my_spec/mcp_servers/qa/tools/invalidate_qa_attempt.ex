defmodule CodeMySpec.McpServers.Qa.Tools.InvalidateQaAttempt do
  @moduledoc """
  Invalidate a prior passed QaAttempt.

  Reserved for engineer-driven audit. Records an audit-stamped
  invalidation event (who/when/why) and preserves the original
  attempt row unchanged. If no other valid pass remains on the
  story, `qa_complete` re-clamps to unsatisfied.

  A non-empty `reason` is required — empty strings are rejected at
  the tool boundary. The reason is what shows up in the QA history
  for the next engineer to understand why the prior pass was
  rejected.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Qa

  schema do
    field :attempt_id, :string,
      required: true,
      doc: "Id of the QaAttempt to invalidate (from a prior list_qa_attempts or submit_qa_result)"

    field :reason, :string,
      required: true,
      doc:
        "Non-empty explanation of why this pass is being invalidated " <>
          "(e.g. 'Shallow probe; tools only, no curl' or 'Bypass attempt found')"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         :ok <- validate_reason(params.reason),
         {:ok, invalidation} <- Qa.invalidate_qa_attempt(scope, params.attempt_id, params.reason) do
      {:reply, invalidation_response(invalidation), frame}
    else
      {:error, :empty_reason} ->
        {:reply,
         Response.error(
           Response.tool(),
           "invalidate_qa_attempt requires a non-empty reason. " <>
             "Explain why this pass is being rejected so future readers can audit the decision."
         ), frame}

      {:error, :attempt_not_found} ->
        {:reply,
         Response.error(
           Response.tool(),
           "invalidate_qa_attempt: no attempt with id `#{params.attempt_id}` exists. " <>
             "Use `list_qa_attempts` to find a valid attempt_id."
         ), frame}

      {:error, :already_invalidated} ->
        {:reply,
         Response.error(
           Response.tool(),
           "invalidate_qa_attempt: attempt `#{params.attempt_id}` is already invalidated. " <>
             "Each attempt can be invalidated at most once."
         ), frame}

      {:error, changeset = %Ecto.Changeset{}} ->
        {:reply, validation_error(changeset), frame}

      {:error, reason} ->
        {:reply, error_response(reason), frame}
    end
  end

  defp validate_reason(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> {:error, :empty_reason}
      _ -> :ok
    end
  end

  defp validate_reason(_), do: {:error, :empty_reason}

  defp invalidation_response(invalidation) do
    Response.text(
      Response.tool(),
      """
      QaAttempt invalidated.

      invalidation_id: #{invalidation.id}
      qa_attempt_id:   #{invalidation.qa_attempt_id}
      invalidated_by_user_id: #{invalidation.invalidated_by_user_id}
      invalidated_at:  #{invalidation.invalidated_at}
      reason: #{invalidation.reason}

      The original attempt is preserved in history. qa_complete will re-clamp
      if no other valid pass remains on the story.
      """
    )
  end

  defp validation_error(changeset) do
    errors =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {k, v}, acc ->
          String.replace(acc, "%{#{k}}", safe_to_string(v))
        end)
      end)
      |> Enum.map_join("\n", fn {field, messages} ->
        "  #{field}: #{Enum.join(messages, ", ")}"
      end)

    Response.error(Response.tool(), "Invalid invalidate_qa_attempt payload:\n#{errors}")
  end

  defp safe_to_string(value) when is_binary(value), do: value
  defp safe_to_string(value) when is_atom(value) or is_number(value), do: to_string(value)
  defp safe_to_string(value), do: inspect(value)

  defp error_response(reason) when is_atom(reason),
    do: Response.error(Response.tool(), "invalidate_qa_attempt failed: #{reason}")

  defp error_response(reason),
    do: Response.error(Response.tool(), "invalidate_qa_attempt failed: #{inspect(reason)}")
end
