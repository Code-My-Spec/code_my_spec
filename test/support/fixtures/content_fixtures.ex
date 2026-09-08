defmodule CodeMySpec.ContentFixtures do
  @moduledoc """
  Test data for `CodeMySpec.Content`.

  NOTE: project and account parameters are kept for backwards compatibility
  but are ignored since Content schema no longer has multi-tenant fields.
  """

  alias CodeMySpec.Content.Content
  alias CodeMySpec.Repo

  def valid_content_attributes(_project \\ nil, _account \\ nil, attrs \\ %{}) do
    unique_id = System.unique_integer([:positive])

    Enum.into(attrs, %{
      slug: "test-content-#{unique_id}",
      content_type: "blog",
      processed_content: "<h1>Test Content</h1><p>This is test content.</p>",
      protected: false,
      metadata: %{}
    })
  end

  def content_fixture(_project \\ nil, _account \\ nil, attrs \\ %{}) do
    %Content{}
    |> Content.changeset(valid_content_attributes(nil, nil, attrs))
    |> Repo.insert!()
  end

  def blog_post_fixture(_project \\ nil, _account \\ nil, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        content_type: "blog",
        processed_content: "<h1>Blog Post</h1><p>This is a blog post.</p>",
        meta_title: "Test Blog Post",
        meta_description: "A test blog post for testing purposes"
      })

    content_fixture(nil, nil, attrs)
  end

  def page_fixture(_project \\ nil, _account \\ nil, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        content_type: "page",
        processed_content: "<h1>Page</h1><p>This is a page.</p>",
        meta_title: "Test Page",
        meta_description: "A test page for testing purposes"
      })

    content_fixture(nil, nil, attrs)
  end

  def landing_page_fixture(_project \\ nil, _account \\ nil, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        content_type: "landing",
        processed_content: "<h1>Landing Page</h1><p>This is a landing page.</p>",
        meta_title: "Test Landing Page",
        meta_description: "A test landing page",
        og_title: "Test Landing Page",
        og_description: "A test landing page for testing purposes",
        og_image: "https://example.com/image.jpg"
      })

    content_fixture(nil, nil, attrs)
  end

  def published_content_fixture(_project \\ nil, _account \\ nil, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        publish_at: DateTime.utc_now() |> DateTime.add(-1, :day),
        processed_content: "<h1>Test Content</h1><p>This is test content.</p>"
      })

    content_fixture(nil, nil, attrs)
  end

  def scheduled_content_fixture(_project \\ nil, _account \\ nil, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        publish_at: DateTime.utc_now() |> DateTime.add(1, :day),
        processed_content: "<h1>Scheduled Content</h1><p>This is scheduled content.</p>"
      })

    content_fixture(nil, nil, attrs)
  end

  def expired_content_fixture(_project \\ nil, _account \\ nil, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        publish_at: DateTime.utc_now() |> DateTime.add(-7, :day),
        expires_at: DateTime.utc_now() |> DateTime.add(-1, :day),
        processed_content: "<h1>Expired Content</h1><p>This is expired content.</p>"
      })

    content_fixture(nil, nil, attrs)
  end

  def protected_content_fixture(_project \\ nil, _account \\ nil, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        protected: true,
        processed_content: "<h1>Protected Content</h1><p>This is protected content.</p>"
      })

    content_fixture(nil, nil, attrs)
  end

  def failed_content_fixture(_project \\ nil, _account \\ nil, attrs \\ %{}) do
    # Note: parse_status and parse_errors no longer exist in Content schema
    # This fixture is kept for backwards compatibility but just creates regular content
    content_fixture(nil, nil, attrs)
  end
end
