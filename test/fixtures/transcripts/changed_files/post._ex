defmodule TestPhoenixProject.Blog.Post do
  use Ecto.Schema
  import Ecto.Changeset

  schema "posts" do
    field :title, :string
    field :content, :string
    field :published, :boolean, default: false
    field :user_id, :id

    timestamps(type: :utc_datetime)
  end

  def title_slug(%__MODULE__{title: title}) do
    title
    |> String.downcase()
    |> String.replace(~r/\s+/, "-")
  end

  @doc false
  def changeset(post, attrs, user_scope) do
    post
    |> cast(attrs, [:title, :content, :published])
    |> validate_required([:title, :content, :published])
    |> put_change(:user_id, user_scope.user.id)
  end
end
