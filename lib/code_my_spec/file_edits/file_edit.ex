defmodule CodeMySpec.FileEdits.FileEdit do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "file_edits" do
    field :external_session_id, :string
    field :agent_id, :string
    field :file_path, :string

    timestamps(type: :utc_datetime)
  end
end
