defmodule CodeMySpec.AppInstances.Tools.UnshareCopyApp do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.AppInstances.Tools.Target
  alias CodeMySpec.Workspaces.PreviewTunnel

  @impl true
  def name, do: "unshare_copy_app"

  @impl true
  def description do
    """
    Drop the caller's own copy's shared preview.

    Removes the ingress rule that pointed its hostname at this copy's app and
    the DNS record behind it, and clears the copy's own recorded address. See
    `ShareCopyApp`.

    A no-op on main, whose tunnel is the project's rather than this call's to
    remove, and on a copy that was never shared — see `PreviewTunnel.release/1`.

    By default this resolves the caller's active source checkout's default app
    instance. `instance_id` can select another instance from that same source;
    ownership is checked before the preview is released.
    """
  end

  @impl true
  def params do
    %{
      instance_id:
        {:meta, :string, [description: "App instance UUID from `list_working_copies`."]}
    }
  end

  @impl true
  def call(params, context) do
    case CodeMySpec.Tools.project_scope(context) do
      {:ok, scope} -> unshare(scope, context, Map.get(params, :instance_id))
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  defp unshare(scope, context, instance_id) do
    case Target.own_default(scope, context, instance_id) do
      {:ok, instance} -> release(instance)
      _ -> {:error, "This call has no working copy of its own, so there is nothing to unshare."}
    end
  end

  defp release(instance) do
    case PreviewTunnel.release(instance) do
      :ok -> {:ok, "No longer shared."}
      {:error, reason} -> {:error, "Could not stop sharing: #{inspect(reason)}"}
    end
  end

  defp refusal(:missing_active_project) do
    "This call names no project, so there is no working copy to unshare a preview for."
  end

  defp refusal(reason), do: "This call has no usable project scope (#{inspect(reason)})."
end
