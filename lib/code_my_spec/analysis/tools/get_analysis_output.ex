defmodule CodeMySpec.Analysis.Tools.GetAnalysisOutput do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.Run

  @impl true
  def name, do: "get_analysis_output"

  @impl true
  def description do
    """
    Read retained analyzer stdout/stderr without starting another run.

    Supply run_id, or source to select its latest run in this working copy
    (including partial, failed, and running runs). The JSON response identifies
    the run and carries an unmodified output slice. Continue with that run_id
    and next_offset, never source, to keep pages tied to the same run.

    Offsets count Unicode codepoints. Concatenating output slices reconstructs
    the retained text exactly. This cannot recover output discarded before it
    reached the ledger. output_available distinguishes missing output from an
    empty string; neither a missing exit status nor missing output means success.

    A "queued" run also carries queued_seconds (how long it has waited) and
    harness_connected (whether anything able to run it is even reachable for
    this working copy right now). harness_connected: false means the wait has
    no end in sight on its own; it is not evidence that the run will fail.
    """
  end

  @impl true
  def params do
    %{
      run_id:
        {:meta, :integer, [description: "Retained run ID. Supply this or source, not both."]},
      source:
        {:meta, :string, [description: "Select the latest compiler, credo, exunit, or spex run."]},
      offset:
        {:meta, :integer, [description: "Zero-based Unicode codepoint offset. Default: 0."]},
      limit: {:meta, :integer, [description: "Codepoints to return. Default and maximum: 2000."]}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, page} <- fetch(params, context), do: {:ok, Jason.encode!(page)}
  end

  # A script gets the page itself, a table: `r.output`, `r.next_offset`. Without
  # this a script was handed the JSON text, `r.output` was nil at every offset,
  # and an agent paging a failure read "no output" for a run that had it
  # (issue ad6c7674).
  @impl true
  def script_result(params, context) do
    with {:ok, page} <- fetch(params, context) do
      {:ok, Map.new(page, fn {key, value} -> {to_string(key), value} end)}
    end
  end

  defp fetch(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         :ok <- working_copy(scope),
         {:ok, selector} <- selector(params),
         {:ok, offset, limit} <- pagination(params),
         %Run{} = run <- Analysis.output_run(scope, selector),
         {:ok, page} <- output_page(run, offset, limit) do
      {:ok, page}
    else
      nil -> {:error, "No retained run matches in this working copy."}
      {:error, reason} -> {:error, to_string(reason)}
    end
  end

  defp working_copy(%{active_working_copy_id: id}) when is_binary(id), do: :ok
  defp working_copy(_scope), do: {:error, "Select a working copy before reading analyzer output."}

  defp selector(params) do
    case {params[:run_id], params[:source]} do
      {id, nil} when is_integer(id) and id > 0 -> {:ok, {:id, id}}
      {nil, source} when is_binary(source) -> source_selector(source)
      _ -> {:error, "Supply exactly one positive run_id or analyzer source."}
    end
  end

  defp source_selector(source) do
    if source in Run.sources(),
      do: {:ok, {:source, source}},
      else: {:error, "Unknown analyzer source."}
  end

  defp pagination(params) do
    offset = Map.get(params, :offset) || 0
    limit = Map.get(params, :limit) || 2000

    if is_integer(offset) and offset >= 0 and is_integer(limit) and limit in 1..2000,
      do: {:ok, offset, limit},
      else: {:error, "offset must be nonnegative and limit must be between 1 and 2000."}
  end

  defp output_page(run, offset, limit) do
    codepoints = String.codepoints(run.output || "")
    total = length(codepoints)

    if offset <= total do
      output = codepoints |> Enum.slice(offset, limit) |> Enum.join()
      next = min(offset + limit, total)

      {:ok,
       Map.merge(
         %{
           run_id: run.id,
           source: run.source,
           status: status_label(run),
           kind: run.kind,
           exit_status: run.exit_status,
           start_commit: run.start_commit,
           completed_commit: run.completed_commit,
           output_available: not is_nil(run.output),
           output: output,
           offset: offset,
           total_codepoints: total,
           next_offset: if(next < total, do: next, else: nil),
           retention: "Retained ledger output; upstream truncation cannot be recovered here."
         },
         Analysis.queue_wait(run) || %{}
       )}
    else
      {:error, "offset exceeds the retained output length."}
    end
  end

  # A run waiting on a machine-wide slot and one executing are both `:running`
  # in the ledger; `Run.queued?/1` tells them apart.
  defp status_label(%Run{status: :abandoned}), do: "not_run"

  defp status_label(run) do
    if Run.queued?(run), do: "queued", else: to_string(run.status)
  end
end
