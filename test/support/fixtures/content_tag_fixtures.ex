defmodule CodeMySpec.ContentTagFixtures do
  @moduledoc """
  Test data for `CodeMySpec.Content.ContentTag`.
  """

  alias CodeMySpec.Content.ContentTag
  alias CodeMySpec.Repo

  def valid_content_tag_attributes(content, tag, attrs \\ %{}) do
    Enum.into(attrs, %{
      content_id: content.id,
      tag_id: tag.id
    })
  end

  def content_tag_fixture(content, tag, attrs \\ %{}) do
    %ContentTag{}
    |> ContentTag.changeset(valid_content_tag_attributes(content, tag, attrs))
    |> Repo.insert!()
  end
end
