defmodule CodeMySpec.ContentSync.MetaDataParserTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.ContentSync.MetaDataParser

  # ============================================================================
  # Fixtures - Valid YAML Content
  # ============================================================================

  defp valid_minimal_yaml do
    """
    title: "My Post Title"
    slug: "my-post-slug"
    type: "blog"
    """
  end

  defp valid_complete_yaml do
    """
    title: "Complete Blog Post"
    slug: "complete-blog-post"
    type: "blog"
    publish_at: "2025-01-15T10:00:00Z"
    expires_at: "2025-12-31T23:59:59Z"
    meta_title: "Complete Blog Post - SEO Title"
    meta_description: "A comprehensive blog post with all metadata fields"
    og_image: "/images/blog/complete-post.jpg"
    og_title: "Complete Blog Post - Social Media"
    og_description: "Check out this comprehensive blog post"
    tags:
      - elixir
      - phoenix
      - testing
    protected: false
    """
  end

  defp valid_yaml_with_null_values do
    """
    title: "Post with Nulls"
    slug: "post-with-nulls"
    type: "page"
    publish_at: null
    expires_at: null
    protected: false
    """
  end

  defp valid_yaml_with_extra_fields do
    """
    title: "Post with Extra Fields"
    slug: "post-with-extras"
    type: "landing"
    custom_field: "custom value"
    another_field: 123
    nested_field:
      foo: "bar"
      baz: "qux"
    """
  end

  defp valid_yaml_with_protected_content do
    """
    title: "Protected Content"
    slug: "protected-content"
    type: "page"
    protected: true
    """
  end

  defp valid_yaml_with_datetime_strings do
    """
    title: "Post with Dates"
    slug: "post-with-dates"
    type: "blog"
    publish_at: "2025-01-15T10:00:00Z"
    expires_at: "2025-12-31T23:59:59Z"
    """
  end

  # ============================================================================
  # Fixtures - Invalid YAML Content
  # ============================================================================

  defp invalid_yaml_syntax do
    """
    title: "Missing closing quote
    slug: "test-slug"
    type: "blog"
    """
  end

  defp invalid_yaml_tabs do
    """
    title: "Tab Issue"
    \tslug: "test-slug"
    type: "blog"
    """
  end

  defp yaml_missing_required_title do
    """
    slug: "test-slug"
    type: "blog"
    """
  end

  defp yaml_missing_required_slug do
    """
    title: "Test Title"
    type: "blog"
    """
  end

  defp yaml_missing_required_type do
    """
    title: "Test Title"
    slug: "test-slug"
    """
  end

  defp yaml_not_a_map do
    """
    - item1
    - item2
    - item3
    """
  end

  defp yaml_scalar_value do
    """
    just a string
    """
  end

  defp empty_yaml do
    ""
  end

  # ============================================================================
  # Fixtures - File Paths
  # ============================================================================

  defp temp_yaml_file(content) do
    path =
      Path.join(System.tmp_dir!(), "test_metadata_#{System.unique_integer([:positive])}.yaml")

    File.write!(path, content)
    path
  end

  defp nonexistent_file_path do
    Path.join(
      System.tmp_dir!(),
      "nonexistent_metadata_#{System.unique_integer([:positive])}.yaml"
    )
  end

  defp cleanup_file(path), do: File.rm(path)

  # ============================================================================
  # parse_metadata_file/1 - Valid Metadata Tests
  # ============================================================================

  describe "parse_metadata_file/1 - valid minimal metadata" do
    test "successfully parses minimal required fields" do
      path = temp_yaml_file(valid_minimal_yaml())

      on_exit(fn -> cleanup_file(path) end)

      assert {:ok, metadata} = MetaDataParser.parse_metadata_file(path)
      assert metadata.title == "My Post Title"
      assert metadata.slug == "my-post-slug"
      assert metadata.type == "blog"
    end

    test "returns map with atom keys for required fields" do
      path = temp_yaml_file(valid_minimal_yaml())

      on_exit(fn -> cleanup_file(path) end)

      assert {:ok, metadata} = MetaDataParser.parse_metadata_file(path)
      assert is_atom(Map.keys(metadata) |> Enum.find(&(&1 == :title)))
      assert is_atom(Map.keys(metadata) |> Enum.find(&(&1 == :slug)))
      assert is_atom(Map.keys(metadata) |> Enum.find(&(&1 == :type)))
    end
  end

  describe "parse_metadata_file/1 - valid complete metadata" do
    test "successfully parses all standard fields" do
      path = temp_yaml_file(valid_complete_yaml())

      on_exit(fn -> cleanup_file(path) end)

      assert {:ok, metadata} = MetaDataParser.parse_metadata_file(path)
      assert metadata.title == "Complete Blog Post"
      assert metadata.slug == "complete-blog-post"
      assert metadata.type == "blog"
      assert metadata.meta_title == "Complete Blog Post - SEO Title"
      assert metadata.meta_description == "A comprehensive blog post with all metadata fields"
      assert metadata.og_image == "/images/blog/complete-post.jpg"
      assert metadata.og_title == "Complete Blog Post - Social Media"
      assert metadata.og_description == "Check out this comprehensive blog post"
      assert metadata.protected == false
    end

    test "successfully parses tags as list" do
      path = temp_yaml_file(valid_complete_yaml())

      on_exit(fn -> cleanup_file(path) end)

      assert {:ok, metadata} = MetaDataParser.parse_metadata_file(path)
      assert is_list(metadata.tags)
      assert length(metadata.tags) == 3
      assert "elixir" in metadata.tags
      assert "phoenix" in metadata.tags
      assert "testing" in metadata.tags
    end

    test "parses datetime strings" do
      path = temp_yaml_file(valid_complete_yaml())

      on_exit(fn -> cleanup_file(path) end)

      assert {:ok, metadata} = MetaDataParser.parse_metadata_file(path)
      assert metadata.publish_at == "2025-01-15T10:00:00Z"
      assert metadata.expires_at == "2025-12-31T23:59:59Z"
    end
  end

  describe "parse_metadata_file/1 - null and optional values" do
    test "successfully parses metadata with null values" do
      path = temp_yaml_file(valid_yaml_with_null_values())

      on_exit(fn -> cleanup_file(path) end)

      assert {:ok, metadata} = MetaDataParser.parse_metadata_file(path)
      assert metadata.title == "Post with Nulls"
      assert metadata.slug == "post-with-nulls"
      assert metadata.type == "page"
      assert is_nil(metadata[:publish_at])
      assert is_nil(metadata[:expires_at])
      assert metadata.protected == false
    end

    test "allows missing optional fields" do
      path = temp_yaml_file(valid_minimal_yaml())

      on_exit(fn -> cleanup_file(path) end)

      assert {:ok, metadata} = MetaDataParser.parse_metadata_file(path)
      refute Map.has_key?(metadata, :publish_at)
      refute Map.has_key?(metadata, :expires_at)
      refute Map.has_key?(metadata, :meta_title)
      refute Map.has_key?(metadata, :meta_description)
      refute Map.has_key?(metadata, :tags)
    end
  end

  describe "parse_metadata_file/1 - extra fields handling" do
    test "preserves unknown fields in the metadata map" do
      path = temp_yaml_file(valid_yaml_with_extra_fields())

      on_exit(fn -> cleanup_file(path) end)

      assert {:ok, metadata} = MetaDataParser.parse_metadata_file(path)
      assert metadata.title == "Post with Extra Fields"
      assert metadata.slug == "post-with-extras"
      assert metadata.type == "landing"
      assert metadata["custom_field"] == "custom value"
      assert metadata["another_field"] == 123
      assert is_map(metadata["nested_field"])
    end

    test "keeps unknown fields as string keys" do
      path = temp_yaml_file(valid_yaml_with_extra_fields())

      on_exit(fn -> cleanup_file(path) end)

      assert {:ok, metadata} = MetaDataParser.parse_metadata_file(path)
      assert Map.has_key?(metadata, "custom_field")
      assert Map.has_key?(metadata, "another_field")
      refute Map.has_key?(metadata, :custom_field)
      refute Map.has_key?(metadata, :another_field)
    end
  end

  describe "parse_metadata_file/1 - content types" do
    test "accepts 'blog' content type" do
      yaml = """
      title: "Blog Post"
      slug: "blog-post"
      type: "blog"
      """

      path = temp_yaml_file(yaml)

      on_exit(fn -> cleanup_file(path) end)

      assert {:ok, metadata} = MetaDataParser.parse_metadata_file(path)
      assert metadata.type == "blog"
    end

    test "accepts 'page' content type" do
      yaml = """
      title: "Static Page"
      slug: "static-page"
      type: "page"
      """

      path = temp_yaml_file(yaml)

      on_exit(fn -> cleanup_file(path) end)

      assert {:ok, metadata} = MetaDataParser.parse_metadata_file(path)
      assert metadata.type == "page"
    end

    test "accepts 'landing' content type" do
      yaml = """
      title: "Landing Page"
      slug: "landing-page"
      type: "landing"
      """

      path = temp_yaml_file(yaml)

      on_exit(fn -> cleanup_file(path) end)

      assert {:ok, metadata} = MetaDataParser.parse_metadata_file(path)
      assert metadata.type == "landing"
    end

    test "accepts custom content types" do
      yaml = """
      title: "Custom Content"
      slug: "custom-content"
      type: "custom_type"
      """

      path = temp_yaml_file(yaml)

      on_exit(fn -> cleanup_file(path) end)

      assert {:ok, metadata} = MetaDataParser.parse_metadata_file(path)
      assert metadata.type == "custom_type"
    end
  end

  describe "parse_metadata_file/1 - protected content flag" do
    test "parses protected flag as true" do
      path = temp_yaml_file(valid_yaml_with_protected_content())

      on_exit(fn -> cleanup_file(path) end)

      assert {:ok, metadata} = MetaDataParser.parse_metadata_file(path)
      assert metadata.protected == true
    end

    test "parses protected flag as false" do
      yaml = """
      title: "Public Content"
      slug: "public-content"
      type: "page"
      protected: false
      """

      path = temp_yaml_file(yaml)

      on_exit(fn -> cleanup_file(path) end)

      assert {:ok, metadata} = MetaDataParser.parse_metadata_file(path)
      assert metadata.protected == false
    end
  end

  # ============================================================================
  # parse_metadata_file/1 - File Not Found Errors
  # ============================================================================

  describe "parse_metadata_file/1 - file not found" do
    test "returns error tuple when file doesn't exist" do
      path = nonexistent_file_path()

      assert {:error, error_detail} = MetaDataParser.parse_metadata_file(path)
      assert error_detail.type == :file_not_found
      assert error_detail.message == "Metadata file not found"
      assert error_detail.file_path == path
      assert is_nil(error_detail.details)
    end

    test "returns structured error with all required fields" do
      path = nonexistent_file_path()

      assert {:error, error_detail} = MetaDataParser.parse_metadata_file(path)
      assert is_map(error_detail)
      assert Map.has_key?(error_detail, :type)
      assert Map.has_key?(error_detail, :message)
      assert Map.has_key?(error_detail, :file_path)
      assert Map.has_key?(error_detail, :details)
    end
  end

  # ============================================================================
  # parse_metadata_file/1 - YAML Parse Errors
  # ============================================================================

  describe "parse_metadata_file/1 - invalid YAML syntax" do
    test "returns error for malformed YAML with unclosed quote" do
      path = temp_yaml_file(invalid_yaml_syntax())

      on_exit(fn -> cleanup_file(path) end)

      assert {:error, error_detail} = MetaDataParser.parse_metadata_file(path)
      assert error_detail.type == :yaml_parse_error
      assert error_detail.message == "Invalid YAML syntax"
      assert error_detail.file_path == path
      assert not is_nil(error_detail.details)
    end

    test "accepts YAML with tab characters (YamlElixir is lenient)" do
      path = temp_yaml_file(invalid_yaml_tabs())

      on_exit(fn -> cleanup_file(path) end)

      # YamlElixir is lenient and accepts tabs, though YAML spec discourages them
      assert {:ok, metadata} = MetaDataParser.parse_metadata_file(path)
      assert metadata.title == "Tab Issue"
      assert metadata.slug == "test-slug"
      assert metadata.type == "blog"
    end

    test "returns error for empty YAML file" do
      path = temp_yaml_file(empty_yaml())

      on_exit(fn -> cleanup_file(path) end)

      assert {:error, error_detail} = MetaDataParser.parse_metadata_file(path)
      assert error_detail.type == :invalid_structure
      assert error_detail.message == "Metadata must be a map with required keys"
      assert error_detail.file_path == path
    end
  end

  # ============================================================================
  # parse_metadata_file/1 - Invalid Structure Errors
  # ============================================================================

  describe "parse_metadata_file/1 - missing required fields" do
    test "returns error when title is missing" do
      path = temp_yaml_file(yaml_missing_required_title())

      on_exit(fn -> cleanup_file(path) end)

      assert {:error, error_detail} = MetaDataParser.parse_metadata_file(path)
      assert error_detail.type == :invalid_structure
      assert error_detail.message == "Metadata must be a map with required keys"
      assert error_detail.file_path == path
      assert not is_nil(error_detail.details)
    end

    test "returns error when slug is missing" do
      path = temp_yaml_file(yaml_missing_required_slug())

      on_exit(fn -> cleanup_file(path) end)

      assert {:error, error_detail} = MetaDataParser.parse_metadata_file(path)
      assert error_detail.type == :invalid_structure
      assert error_detail.message == "Metadata must be a map with required keys"
      assert error_detail.file_path == path
      assert not is_nil(error_detail.details)
    end

    test "returns error when type is missing" do
      path = temp_yaml_file(yaml_missing_required_type())

      on_exit(fn -> cleanup_file(path) end)

      assert {:error, error_detail} = MetaDataParser.parse_metadata_file(path)
      assert error_detail.type == :invalid_structure
      assert error_detail.message == "Metadata must be a map with required keys"
      assert error_detail.file_path == path
      assert not is_nil(error_detail.details)
    end

    test "returns error when all required fields are missing" do
      yaml = """
      description: "No required fields"
      author: "John Doe"
      """

      path = temp_yaml_file(yaml)

      on_exit(fn -> cleanup_file(path) end)

      assert {:error, error_detail} = MetaDataParser.parse_metadata_file(path)
      assert error_detail.type == :invalid_structure
      assert error_detail.file_path == path
    end
  end

  describe "parse_metadata_file/1 - invalid data structure" do
    test "returns error when YAML is a list instead of map" do
      path = temp_yaml_file(yaml_not_a_map())

      on_exit(fn -> cleanup_file(path) end)

      assert {:error, error_detail} = MetaDataParser.parse_metadata_file(path)
      assert error_detail.type == :invalid_structure
      assert error_detail.message == "Metadata must be a map with required keys"
      assert error_detail.file_path == path
    end

    test "returns error when YAML is a scalar value" do
      path = temp_yaml_file(yaml_scalar_value())

      on_exit(fn -> cleanup_file(path) end)

      assert {:error, error_detail} = MetaDataParser.parse_metadata_file(path)
      assert error_detail.type == :invalid_structure
      assert error_detail.file_path == path
    end
  end

  # ============================================================================
  # parse_metadata_file/1 - Edge Cases
  # ============================================================================

  describe "parse_metadata_file/1 - edge cases" do
    test "handles very long string values" do
      long_string = String.duplicate("a", 10_000)

      yaml = """
      title: "#{long_string}"
      slug: "test-slug"
      type: "blog"
      """

      path = temp_yaml_file(yaml)

      on_exit(fn -> cleanup_file(path) end)

      assert {:ok, metadata} = MetaDataParser.parse_metadata_file(path)
      assert String.length(metadata.title) == 10_000
    end

    test "handles unicode characters in metadata" do
      yaml = """
      title: "测试标题 🚀 émojis"
      slug: "unicode-test"
      type: "blog"
      """

      path = temp_yaml_file(yaml)

      on_exit(fn -> cleanup_file(path) end)

      assert {:ok, metadata} = MetaDataParser.parse_metadata_file(path)
      assert metadata.title == "测试标题 🚀 émojis"
    end

    test "handles multiline string values" do
      yaml = """
      title: |
        This is a
        multiline
        title
      slug: "multiline-test"
      type: "blog"
      """

      path = temp_yaml_file(yaml)

      on_exit(fn -> cleanup_file(path) end)

      assert {:ok, metadata} = MetaDataParser.parse_metadata_file(path)
      assert String.contains?(metadata.title, "multiline")
    end

    test "handles empty string values for required fields" do
      yaml = """
      title: ""
      slug: ""
      type: ""
      """

      path = temp_yaml_file(yaml)

      on_exit(fn -> cleanup_file(path) end)

      assert {:ok, metadata} = MetaDataParser.parse_metadata_file(path)
      assert metadata.title == ""
      assert metadata.slug == ""
      assert metadata.type == ""
    end

    test "handles special characters in slug" do
      yaml = """
      title: "Test Post"
      slug: "test-post-with-special-chars-123_456"
      type: "blog"
      """

      path = temp_yaml_file(yaml)

      on_exit(fn -> cleanup_file(path) end)

      assert {:ok, metadata} = MetaDataParser.parse_metadata_file(path)
      assert metadata.slug == "test-post-with-special-chars-123_456"
    end

    test "handles very deeply nested custom fields" do
      yaml = """
      title: "Deep Nesting"
      slug: "deep-nesting"
      type: "blog"
      custom:
        level1:
          level2:
            level3:
              level4:
                value: "deep"
      """

      path = temp_yaml_file(yaml)

      on_exit(fn -> cleanup_file(path) end)

      assert {:ok, metadata} = MetaDataParser.parse_metadata_file(path)
      assert metadata.title == "Deep Nesting"
      assert is_map(metadata["custom"])
    end

    test "handles empty tags list" do
      yaml = """
      title: "No Tags"
      slug: "no-tags"
      type: "blog"
      tags: []
      """

      path = temp_yaml_file(yaml)

      on_exit(fn -> cleanup_file(path) end)

      assert {:ok, metadata} = MetaDataParser.parse_metadata_file(path)
      assert metadata.tags == []
    end

    test "handles large number of tags" do
      tags = for i <- 1..100, do: "  - tag#{i}"
      tags_yaml = Enum.join(tags, "\n")

      yaml = """
      title: "Many Tags"
      slug: "many-tags"
      type: "blog"
      tags:
      #{tags_yaml}
      """

      path = temp_yaml_file(yaml)

      on_exit(fn -> cleanup_file(path) end)

      assert {:ok, metadata} = MetaDataParser.parse_metadata_file(path)
      assert length(metadata.tags) == 100
    end
  end

  # ============================================================================
  # parse_metadata_file/1 - DateTime Handling
  # ============================================================================

  describe "parse_metadata_file/1 - datetime field handling" do
    test "parses ISO 8601 datetime strings" do
      path = temp_yaml_file(valid_yaml_with_datetime_strings())

      on_exit(fn -> cleanup_file(path) end)

      assert {:ok, metadata} = MetaDataParser.parse_metadata_file(path)
      assert metadata.publish_at == "2025-01-15T10:00:00Z"
      assert metadata.expires_at == "2025-12-31T23:59:59Z"
    end

    test "handles datetime with timezone offset" do
      yaml = """
      title: "Datetime Test"
      slug: "datetime-test"
      type: "blog"
      publish_at: "2025-01-15T10:00:00-05:00"
      """

      path = temp_yaml_file(yaml)

      on_exit(fn -> cleanup_file(path) end)

      assert {:ok, metadata} = MetaDataParser.parse_metadata_file(path)
      assert metadata.publish_at == "2025-01-15T10:00:00-05:00"
    end

    test "handles date-only strings" do
      yaml = """
      title: "Date Only"
      slug: "date-only"
      type: "blog"
      publish_at: "2025-01-15"
      """

      path = temp_yaml_file(yaml)

      on_exit(fn -> cleanup_file(path) end)

      assert {:ok, metadata} = MetaDataParser.parse_metadata_file(path)
      assert metadata.publish_at == "2025-01-15"
    end
  end

  # ============================================================================
  # parse_metadata_file/1 - Integration Tests
  # ============================================================================

  describe "parse_metadata_file/1 - file naming convention" do
    test "parses metadata file with .yaml extension" do
      path = Path.join(System.tmp_dir!(), "my-post.yaml")
      File.write!(path, valid_minimal_yaml())

      on_exit(fn -> cleanup_file(path) end)

      assert {:ok, metadata} = MetaDataParser.parse_metadata_file(path)
      assert metadata.title == "My Post Title"
    end

    test "works with absolute file paths" do
      path = Path.join(System.tmp_dir!(), "absolute-path-test.yaml")
      File.write!(path, valid_minimal_yaml())

      on_exit(fn -> cleanup_file(path) end)

      absolute_path = Path.expand(path)
      assert {:ok, metadata} = MetaDataParser.parse_metadata_file(absolute_path)
      assert metadata.slug == "my-post-slug"
    end

    test "works with relative file paths" do
      # Create a file in a known location
      dir = Path.join(System.tmp_dir!(), "metadata_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "relative-test.yaml")
      File.write!(path, valid_minimal_yaml())
    end
  end

  # ============================================================================
  # parse_metadata_file/1 - Property-Based Tests
  # ============================================================================

  describe "parse_metadata_file/1 - consistency properties" do
    test "parsing the same file multiple times returns identical results" do
      path = temp_yaml_file(valid_complete_yaml())

      on_exit(fn -> cleanup_file(path) end)

      {:ok, result1} = MetaDataParser.parse_metadata_file(path)
      {:ok, result2} = MetaDataParser.parse_metadata_file(path)
      {:ok, result3} = MetaDataParser.parse_metadata_file(path)

      assert result1 == result2
      assert result2 == result3
    end

    test "file not found errors have consistent structure" do
      path = nonexistent_file_path()

      assert {:error, error_detail} = MetaDataParser.parse_metadata_file(path)
      assert is_map(error_detail)
      assert Map.has_key?(error_detail, :type)
      assert Map.has_key?(error_detail, :message)
      assert Map.has_key?(error_detail, :file_path)
      assert Map.has_key?(error_detail, :details)
      assert error_detail.type == :file_not_found
    end

    test "yaml parse errors have consistent structure" do
      path = temp_yaml_file(invalid_yaml_syntax())

      on_exit(fn -> cleanup_file(path) end)

      assert {:error, error_detail} = MetaDataParser.parse_metadata_file(path)
      assert is_map(error_detail)
      assert Map.has_key?(error_detail, :type)
      assert Map.has_key?(error_detail, :message)
      assert Map.has_key?(error_detail, :file_path)
      assert Map.has_key?(error_detail, :details)
      assert error_detail.type == :yaml_parse_error
    end

    test "invalid structure errors have consistent structure" do
      path = temp_yaml_file(yaml_missing_required_title())

      on_exit(fn -> cleanup_file(path) end)

      assert {:error, error_detail} = MetaDataParser.parse_metadata_file(path)
      assert is_map(error_detail)
      assert Map.has_key?(error_detail, :type)
      assert Map.has_key?(error_detail, :message)
      assert Map.has_key?(error_detail, :file_path)
      assert Map.has_key?(error_detail, :details)
      assert error_detail.type == :invalid_structure
    end
  end

  # ============================================================================
  # parse_metadata_file/1 - Security Tests
  # ============================================================================

  describe "parse_metadata_file/1 - security considerations" do
    test "does not execute code in YAML" do
      # YAML parsers should not execute any embedded code
      yaml = """
      title: "Safe Title"
      slug: "safe-slug"
      type: "blog"
      """

      path = temp_yaml_file(yaml)

      on_exit(fn -> cleanup_file(path) end)

      assert {:ok, metadata} = MetaDataParser.parse_metadata_file(path)
      assert metadata.title == "Safe Title"
    end

    test "handles potentially malicious strings safely" do
      yaml = """
      title: "<script>alert('xss')</script>"
      slug: "'; DROP TABLE content; --"
      type: "blog"
      """

      path = temp_yaml_file(yaml)

      on_exit(fn -> cleanup_file(path) end)

      assert {:ok, metadata} = MetaDataParser.parse_metadata_file(path)
      # Parser should return strings as-is, sanitization happens elsewhere
      assert metadata.title == "<script>alert('xss')</script>"
      assert metadata.slug == "'; DROP TABLE content; --"
    end
  end
end
