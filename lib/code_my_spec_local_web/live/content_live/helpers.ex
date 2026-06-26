defmodule CodeMySpecLocalWeb.ContentLive.Helpers do
  @moduledoc false
  # Shared display helpers for the content admin index + detail views.

  def filename(row), do: row.metadata["filename"] || row.metadata["slug"] || to_string(row.id)
  def slug(row), do: row.metadata["slug"] || filename(row)
  def content_type(row), do: row.metadata["content_type"] || row.metadata["type"] || "—"
  def title(row), do: row.metadata["title"] || slug(row)

  def status_class(:success), do: "badge-success"
  def status_class(:error), do: "badge-error"
  def status_class(_), do: "badge-ghost"

  def format_errors(nil), do: ""

  def format_errors(%{message: message, errors: errors})
      when is_map(errors) and map_size(errors) > 0 do
    message <> "\n" <> format_field_errors(errors)
  end

  def format_errors(%{message: message}), do: message
  def format_errors(%{"message" => message}), do: message
  def format_errors(errors), do: inspect(errors)

  # Ecto.Changeset.traverse_errors output: %{"field" => ["msg", ...]} with
  # nested maps for embeds. Render one "field: messages" line per field.
  defp format_field_errors(errors) do
    errors
    |> Enum.map(fn {field, msgs} -> "#{field}: #{format_field_msgs(msgs)}" end)
    |> Enum.sort()
    |> Enum.join("\n")
  end

  defp format_field_msgs(msgs) when is_list(msgs), do: Enum.join(msgs, ", ")
  defp format_field_msgs(msgs) when is_map(msgs), do: format_field_errors(msgs)
  defp format_field_msgs(msg), do: to_string(msg)

  def project_slug(project) do
    (project.name || "project")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
