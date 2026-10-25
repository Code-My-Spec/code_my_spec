defmodule CodeMySpec.AppInstances.Tools.Presentation do
  @moduledoc false

  # An explicit allowlist: encrypted tunnel credentials and internal policy maps
  # must never become discovery output when new schema fields are added.
  def row(instance) do
    %{
      "id" => instance.id,
      "project_id" => instance.project_id,
      "environment_id" => instance.environment_id,
      "device_id" => instance.device_id,
      "working_copy_id" => instance.working_copy_id,
      "source_root" => instance.source_root,
      "default" => instance.default,
      "persistent" => instance.persistent,
      "status" => instance.status,
      "checked_at" => timestamp(instance.checked_at),
      "url" => instance.url,
      "commit" => instance.commit,
      "serving_commit" => instance.serving_commit,
      "deployment_image" => instance.deployment_image,
      "preview_status" => instance.preview_status,
      "preview_checked_at" => timestamp(instance.preview_checked_at),
      "preview_url" => instance.preview_url
    }
  end

  defp timestamp(nil), do: nil
  defp timestamp(value), do: DateTime.to_iso8601(value)
end
