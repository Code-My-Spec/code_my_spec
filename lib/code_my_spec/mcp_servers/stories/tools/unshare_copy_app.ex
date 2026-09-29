defmodule CodeMySpec.McpServers.Stories.Tools.UnshareCopyApp do
  @moduledoc """
  Drop the caller's own copy's shared preview.

  Removes the ingress rule that pointed its hostname at this copy's app and
  the DNS record behind it, and clears the copy's own recorded address. See
  `ShareCopyApp`.

  A no-op on main, whose tunnel is the project's rather than this call's to
  remove, and on a copy that was never shared — see `PreviewTunnel.release/1`.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.Workspaces.PreviewTunnel

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} -> {:reply, unshare(scope), frame}
      {:error, reason} -> {:reply, Response.tool() |> Response.error(refusal(reason)), frame}
    end
  end

  defp unshare(%{active_working_copy_id: id}) when is_binary(id) do
    case WorkingCopies.fetch(id) do
      {:ok, copy} -> release(copy)
      {:error, reason} -> Response.tool() |> Response.error("Could not look up this copy: #{inspect(reason)}")
    end
  end

  defp unshare(_scope) do
    Response.tool()
    |> Response.error("This call has no working copy of its own, so there is nothing to unshare.")
  end

  defp release(copy) do
    case PreviewTunnel.release(copy) do
      :ok -> Response.tool() |> Response.text("No longer shared.")
      {:error, reason} -> Response.tool() |> Response.error("Could not stop sharing: #{inspect(reason)}")
    end
  end

  defp refusal(:no_working_dir) do
    "This call names no project, so there is no working copy to unshare a preview for."
  end

  defp refusal(reason), do: "This call has no usable project scope (#{inspect(reason)})."
end
