defmodule CodeMySpec.Projects.Source do
  @moduledoc "Source material selected for a project, not necessarily its development checkout."
  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    field(:kind, Ecto.Enum, values: [:github, :local])
    field(:repository_url, :string)
    field(:ref, :string)
    field(:device_id, Ecto.UUID)
    field(:path, :string)
    field(:assessment, Ecto.Enum, values: [:pending, :phoenix, :reference], default: :pending)
  end

  # Inspection results are deliberately not user-editable selection attributes.
  def changeset(source, attrs) do
    source
    |> cast(attrs, [:kind, :repository_url, :ref, :device_id, :path])
    |> validate_required([:kind])
    |> validate_length(:ref, max: 255)
    |> validate_length(:path, max: 4096)
    |> validate_location()
  end

  defp validate_location(changeset) do
    case get_field(changeset, :kind) do
      :github ->
        changeset
        |> validate_required([:repository_url])
        |> validate_format(
          :repository_url,
          ~r{\Ahttps://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/?\z},
          message: "must be a GitHub repository URL"
        )
        |> put_change(:device_id, nil)
        |> put_change(:path, nil)

      :local ->
        changeset
        |> validate_required([:device_id, :path])
        |> validate_format(:path, ~r{\A(?:/|[A-Za-z]:[\\/]|\\\\)},
          message: "must be an absolute path on the selected device"
        )
        |> put_change(:repository_url, nil)
        |> put_change(:ref, nil)

      _ ->
        changeset
    end
  end
end
