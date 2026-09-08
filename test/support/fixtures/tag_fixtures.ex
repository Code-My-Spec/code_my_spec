defmodule CodeMySpec.TagFixtures do
  @moduledoc """
  Test data for `CodeMySpec.Content.Tag`.

  Note: Tags are single-tenant (no account_id/project_id).
  The project and account parameters are kept for backwards compatibility
  but are ignored.
  """

  alias CodeMySpec.Content.TagRepository

  def valid_tag_attributes(_project \\ nil, _account \\ nil, attrs \\ %{}) do
    unique_id = System.unique_integer([:positive])

    Enum.into(attrs, %{
      name: "Test Tag #{unique_id}"
    })
  end

  def tag_fixture(_project \\ nil, _account \\ nil, attrs \\ %{}) do
    attrs = valid_tag_attributes(nil, nil, attrs)
    {:ok, tag} = TagRepository.upsert_tag(attrs.name)
    tag
  end

  def uppercase_tag_fixture(_project \\ nil, _account \\ nil, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{name: "UPPERCASE TAG"})
    tag_fixture(nil, nil, attrs)
  end

  def mixed_case_tag_fixture(_project \\ nil, _account \\ nil, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{name: "MiXeD CaSe TaG"})
    tag_fixture(nil, nil, attrs)
  end

  def special_chars_tag_fixture(_project \\ nil, _account \\ nil, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{name: "Tag with Special-Chars & Symbols!"})
    tag_fixture(nil, nil, attrs)
  end

  def long_tag_fixture(_project \\ nil, _account \\ nil, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{name: String.duplicate("a", 50)})
    tag_fixture(nil, nil, attrs)
  end
end
