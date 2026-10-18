defmodule CodeMySpec.WorkingCopies.Tools.ShareCopyApp do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.Workspaces.PreviewTunnel

  @impl true
  def name, do: "share_copy_app"

  @impl true
  def description do
    """
    Give the caller's own copy a public preview address.

    Shares its device's tunnel rather than provisioning one of its own —
    criteria 1586/1587: a same-device sibling's connector can already reach
    this copy's local port, so its hostname is added to that tunnel's ingress
    instead of standing up a second connector nothing needs.

    Always the caller's own copy, never a parameter — same "an agent cannot
    reach another copy" reasoning as `EnsureAppRunning`/`StopApp`. Refused
    while the copy's own app is not serving: sharing points a public hostname
    at a local port, and a port nothing is listening on yet is exactly the gap
    between "reported" and "actually up" story 1108's `app_url` exists to
    close.
    """
  end

  @impl true
  def params do
    %{}
  end

  @impl true
  def call(_params, context) do
    case CodeMySpec.Tools.project_scope(context) do
      {:ok, scope} -> share(scope)
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  defp share(%{active_working_copy_id: id}) when is_binary(id) do
    case WorkingCopies.fetch(id) do
      {:ok, %{app_status: "serving"} = copy} -> ensure_shared(copy)
      {:ok, _copy} -> {:error, "This copy's app is not serving yet — nothing to share."}
      {:error, reason} -> {:error, "Could not look up this copy: #{inspect(reason)}"}
    end
  end

  defp share(_scope) do
    {:error, "This call has no working copy of its own, so there is nothing to share."}
  end

  defp ensure_shared(copy) do
    case PreviewTunnel.ensure(copy) do
      {:ok, credentials} ->
        {:ok, "Shared at https://#{credentials.hostname}."}

      {:error, :no_tunnel_on_this_device} ->
        {:error,
         "No tunnel exists yet on this device to share. Main's own checkout provisions " <>
           "the first one, at onboarding."}

      {:error, :not_the_main_copy} ->
        {:error, "This copy has no app of its own recorded yet, so there is nothing to share."}

      {:error, reason} ->
        {:error, "Could not share this copy's preview: #{inspect(reason)}"}
    end
  end

  defp refusal(:missing_active_project) do
    "This call names no project, so there is no working copy to share a preview for."
  end

  defp refusal(reason), do: "This call has no usable project scope (#{inspect(reason)})."
end
