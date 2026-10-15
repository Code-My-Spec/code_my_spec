defmodule CodeMySpec.McpServers.Analysis.Tools.GetAnalysisOutput do
  @moduledoc """
  Read retained analyzer stdout/stderr without starting another run.

  Supply run_id, or source to select its latest run in this working copy
  (including partial, failed, and running runs). The JSON response identifies
  the run and carries an unmodified output slice. Continue with that run_id
  and next_offset, never source, to keep pages tied to the same run.

  Offsets count Unicode codepoints. Concatenating output slices reconstructs
  the retained text exactly. This cannot recover output discarded before it
  reached the ledger. output_available distinguishes missing output from an
  empty string; neither a missing exit status nor missing output means success.
  """
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.McpServers.Validators

  schema do
    field :run_id, :integer, doc: "Retained run ID. Supply this or source, not both."
    field :source, :string, doc: "Select the latest compiler, credo, exunit, or spex run."
    field :offset, :integer, doc: "Zero-based Unicode codepoint offset. Default: 0."
    field :limit, :integer, doc: "Codepoints to return. Default and maximum: 2000."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         :ok <- working_copy(scope),
         {:ok, selector} <- selector(params),
         {:ok, offset, limit} <- pagination(params),
         %Run{} = run <- Analysis.output_run(scope, selector),
         {:ok, page} <- output_page(run, offset, limit) do
      {:reply, Response.tool() |> Response.text(Jason.encode!(page)), frame}
    else
      nil -> failure("No retained run matches in this working copy.", frame)
      {:error, reason} -> failure(to_string(reason), frame)
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
    offset = Map.get(params, :offset, 0)
    limit = Map.get(params, :limit, 2000)

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
       %{
         run_id: run.id,
         source: run.source,
         status: run.status,
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
       }}
    else
      {:error, "offset exceeds the retained output length."}
    end
  end

  defp failure(reason, frame),
    do: {:reply, Response.tool() |> Response.error(reason), frame}
end
