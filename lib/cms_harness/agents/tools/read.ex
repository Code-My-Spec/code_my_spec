defmodule CmsHarness.Agents.Tools.Read do
  @moduledoc """
  Alloy's read tool, with a long result spilled to a file (`Spill`) instead of
  cut: a 1,500-line file read whole comes back as a notice the agent can page
  through with `offset`/`limit`.

  Reads, but never writes, a few places outside the checkout: the source of
  its path dependencies (`DepRoots`) and its own app instance's state and log.
  """

  @behaviour Alloy.Tool

  alias Alloy.Tool.Core.Read
  alias CmsHarness.Agents.DepRoots
  alias CmsHarness.Agents.Spill
  alias CmsHarness.AppInstance

  @impl true
  defdelegate name(), to: Read

  @impl true
  defdelegate description(), to: Read

  @impl true
  defdelegate input_schema(), to: Read

  @impl true
  defdelegate max_result_chars(), to: Read

  @impl true
  def execute(input, context) do
    case Read.execute(input, with_read_only_roots(input, context)) do
      {:ok, text} -> {:ok, Spill.shape(text, context, name())}
      other -> other
    end
  end

  # A path refused as outside the checkout may be one the agent may read but
  # not write: a path dependency's source, which the project builds from, or
  # its own app instance's state and log. `:read_only_roots` in the context
  # replaces `read_only_roots/1`, so a test needs no `mix`.
  defp with_read_only_roots(input, %{allowed_paths: allowed} = context) when is_list(allowed) do
    case Alloy.Tool.resolve_path(input["file_path"] || "", context) do
      {:ok, _path} ->
        context

      {:error, _refused} ->
        roots = Map.get(context, :read_only_roots, &read_only_roots/1).(context)
        %{context | allowed_paths: allowed ++ roots}
    end
  end

  defp with_read_only_roots(_input, context), do: context

  defp read_only_roots(%{working_directory: wd} = context) when is_binary(wd),
    do: DepRoots.for(wd) ++ AppInstance.own_dirs(wd, context[:working_copy_id])

  defp read_only_roots(_context), do: []
end
