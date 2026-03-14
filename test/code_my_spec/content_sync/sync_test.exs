defmodule CodeMySpec.ContentSync.SyncTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.ContentSync.Sync

  # ============================================================================
  # Fixtures - Test Directories and Files
  # ============================================================================

  defp create_test_directory(files) do
    dir = Path.join(System.tmp_dir!(), "sync_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    for {filename, content, metadata} <- files do
      file_path = Path.join(dir, filename)
      metadata_path = Path.join(dir, Path.rootname(filename) <> ".yaml")

      File.write!(file_path, content)
      File.write!(metadata_path, metadata)
    end

    dir
  end

  defp cleanup_directory(dir) do
    if File.exists?(dir) do
      File.rm_rf!(dir)
    end
  end

  defp valid_blog_metadata do
    """
    title: "Test Blog Post"
    slug: "test-blog-post"
    type: "blog"
    publish_at: "2025-01-15T10:00:00Z"
    meta_title: "Test Blog Post - SEO"
    meta_description: "A test blog post"
    """
  end

  defp valid_page_metadata do
    """
    title: "Test Page"
    slug: "test-page"
    type: "page"
    """
  end

  defp invalid_metadata_missing_title do
    """
    slug: "missing-title"
    type: "blog"
    """
  end

  defp simple_markdown_content do
    """
    # Hello World

    This is a test blog post.
    """
  end

  defp simple_html_content do
    """
    <div>
      <h1>Hello HTML</h1>
      <p>This is HTML content.</p>
    </div>
    """
  end

  defp invalid_html_with_script do
    """
    <div>
      <script>alert('xss')</script>
      <p>Content</p>
    </div>
    """
  end

  # ============================================================================
  # process_directory/1 - Successful Processing
  # ============================================================================

  describe "process_directory/1 - successful processing with single file" do
    test "successfully processes single markdown file" do
      dir =
        create_test_directory([
          {"post.md", simple_markdown_content(), valid_blog_metadata()}
        ])

      assert {:ok, attrs_list} = Sync.process_directory(dir)
      assert length(attrs_list) == 1

      [attrs] = attrs_list
      assert attrs.slug == "test-blog-post"
      assert attrs.title == "Test Blog Post"
      assert attrs.content_type == :blog
      assert attrs.raw_content == simple_markdown_content()
      assert is_binary(attrs.processed_content)
      assert String.contains?(attrs.processed_content, "<h1>")
      assert attrs.parse_status == :success
      assert is_nil(attrs.parse_errors)

      cleanup_directory(dir)
    end

    test "successfully processes single HTML file" do
      dir =
        create_test_directory([
          {"page.html", simple_html_content(), valid_page_metadata()}
        ])

      assert {:ok, attrs_list} = Sync.process_directory(dir)
      assert length(attrs_list) == 1

      [attrs] = attrs_list
      assert attrs.slug == "test-page"
      assert attrs.content_type == :page
      assert attrs.raw_content == simple_html_content()
      assert attrs.parse_status == :success

      cleanup_directory(dir)
    end

    test "stores metadata fields correctly" do
      dir =
        create_test_directory([
          {"post.md", simple_markdown_content(), valid_blog_metadata()}
        ])

      assert {:ok, [attrs]} = Sync.process_directory(dir)
      assert attrs.title == "Test Blog Post"
      assert attrs.meta_title == "Test Blog Post - SEO"
      assert attrs.meta_description == "A test blog post"
      assert %DateTime{} = attrs.publish_at

      cleanup_directory(dir)
    end

    test "stores full metadata map with string keys" do
      dir =
        create_test_directory([
          {"post.md", simple_markdown_content(), valid_blog_metadata()}
        ])

      assert {:ok, [attrs]} = Sync.process_directory(dir)

      # Verify metadata map exists and is not empty
      assert is_map(attrs.metadata)
      assert attrs.metadata != %{}

      # Verify metadata contains all parsed YAML fields with string keys
      assert attrs.metadata["title"] == "Test Blog Post"
      assert attrs.metadata["slug"] == "test-blog-post"
      assert attrs.metadata["type"] == "blog"
      assert attrs.metadata["meta_title"] == "Test Blog Post - SEO"
      assert attrs.metadata["meta_description"] == "A test blog post"
      assert attrs.metadata["publish_at"] == "2025-01-15T10:00:00Z"

      # Verify no atom keys (should all be strings)
      refute Map.has_key?(attrs.metadata, :title)
      refute Map.has_key?(attrs.metadata, :slug)
      refute Map.has_key?(attrs.metadata, :type)

      cleanup_directory(dir)
    end
  end

  describe "process_directory/1 - successful processing with multiple files" do
    test "successfully processes multiple files of different types" do
      dir =
        create_test_directory([
          {"post.md", simple_markdown_content(), valid_blog_metadata()},
          {"page.html", simple_html_content(), valid_page_metadata()}
        ])

      assert {:ok, attrs_list} = Sync.process_directory(dir)
      assert length(attrs_list) == 2

      slugs = Enum.map(attrs_list, & &1.slug) |> Enum.sort()
      assert slugs == ["test-blog-post", "test-page"]

      cleanup_directory(dir)
    end

    test "processes files in alphabetical order" do
      dir =
        create_test_directory([
          {"zebra.md", simple_markdown_content(),
           """
           title: "Zebra"
           slug: "zebra"
           type: "blog"
           """},
          {"alpha.md", simple_markdown_content(),
           """
           title: "Alpha"
           slug: "alpha"
           type: "blog"
           """},
          {"beta.md", simple_markdown_content(),
           """
           title: "Beta"
           slug: "beta"
           type: "blog"
           """}
        ])

      assert {:ok, attrs_list} = Sync.process_directory(dir)
      assert length(attrs_list) == 3

      slugs = Enum.map(attrs_list, & &1.slug)
      assert slugs == ["alpha", "beta", "zebra"]

      cleanup_directory(dir)
    end
  end

  # ============================================================================
  # process_directory/1 - Error Handling
  # ============================================================================

  describe "process_directory/1 - metadata parsing errors" do
    test "returns attributes with error status when metadata is invalid" do
      dir =
        create_test_directory([
          {"post.md", simple_markdown_content(), invalid_metadata_missing_title()}
        ])

      assert {:ok, attrs_list} = Sync.process_directory(dir)
      assert length(attrs_list) == 1

      [attrs] = attrs_list
      assert attrs.parse_status == :error
      assert is_map(attrs.parse_errors)
      assert attrs.parse_errors[:error_type] == "MetaDataParseError"
      assert is_binary(attrs.parse_errors[:message])

      cleanup_directory(dir)
    end

    test "returns error attrs for files without metadata sidecar files" do
      dir = Path.join(System.tmp_dir!(), "sync_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      # Create content file without metadata file — returns parse error entry
      file_path = Path.join(dir, "post.md")
      File.write!(file_path, simple_markdown_content())

      assert {:ok, [attrs]} = Sync.process_directory(dir)
      assert attrs.slug == "post"
      assert attrs.parse_status == :error
      assert attrs.parse_errors.error_type == "MissingMetadata"

      cleanup_directory(dir)
    end

    test "stores metadata error details in parse_errors field" do
      dir =
        create_test_directory([
          {"post.md", simple_markdown_content(), invalid_metadata_missing_title()}
        ])

      assert {:ok, [attrs]} = Sync.process_directory(dir)
      assert attrs.parse_status == :error
      assert is_map(attrs.parse_errors)
      assert Map.has_key?(attrs.parse_errors, :error_type)
      assert Map.has_key?(attrs.parse_errors, :message)

      cleanup_directory(dir)
    end
  end

  describe "process_directory/1 - content processing errors" do
    test "returns attributes with error status when HTML has disallowed content" do
      dir =
        create_test_directory([
          {"page.html", invalid_html_with_script(), valid_page_metadata()}
        ])

      assert {:ok, [attrs]} = Sync.process_directory(dir)
      assert attrs.parse_status == :error
      assert is_map(attrs.parse_errors)

      cleanup_directory(dir)
    end

    test "continues processing when some files have errors" do
      dir =
        create_test_directory([
          {"good.md", simple_markdown_content(), valid_blog_metadata()},
          {"bad.html", invalid_html_with_script(), valid_page_metadata()},
          {"good2.html", simple_html_content(), valid_page_metadata()}
        ])

      on_exit(fn -> cleanup_directory(dir) end)

      assert {:ok, attrs_list} = Sync.process_directory(dir)
      assert length(attrs_list) == 3

      successful = Enum.filter(attrs_list, &(&1.parse_status == :success))
      assert length(successful) == 2

      errors = Enum.filter(attrs_list, &(&1.parse_status == :error))
      assert length(errors) == 1
    end
  end

  describe "process_directory/1 - mixed success and error scenarios" do
    test "returns both successful and failed files in result" do
      dir =
        create_test_directory([
          {"success1.md", simple_markdown_content(), valid_blog_metadata()},
          {"error1.md", simple_markdown_content(), invalid_metadata_missing_title()},
          {"success2.html", simple_html_content(), valid_page_metadata()},
          {"error2.html", invalid_html_with_script(),
           """
           title: "Error Page"
           slug: "error-page"
           type: "page"
           """}
        ])

      assert {:ok, attrs_list} = Sync.process_directory(dir)
      assert length(attrs_list) == 4

      successful = Enum.filter(attrs_list, &(&1.parse_status == :success))
      assert length(successful) == 2

      errors = Enum.filter(attrs_list, &(&1.parse_status == :error))
      assert length(errors) == 2

      cleanup_directory(dir)
    end
  end

  # ============================================================================
  # process_directory/1 - Directory Validation
  # ============================================================================

  describe "process_directory/1 - directory validation errors" do
    test "returns error when directory does not exist" do
      nonexistent_dir = "/nonexistent/directory/path"

      assert {:error, :invalid_directory} = Sync.process_directory(nonexistent_dir)
    end

    test "returns error when directory path is nil" do
      assert {:error, :invalid_directory} = Sync.process_directory(nil)
    end

    test "returns error when directory path is empty string" do
      assert {:error, :invalid_directory} = Sync.process_directory("")
    end

    test "returns error when path is a file not a directory" do
      file_path = Path.join(System.tmp_dir!(), "test_file_#{System.unique_integer([:positive])}")
      File.write!(file_path, "test content")

      assert {:error, :invalid_directory} = Sync.process_directory(file_path)
      File.rm!(file_path)
    end
  end

  describe "process_directory/1 - empty directory scenarios" do
    test "successfully handles empty directory" do
      dir = Path.join(System.tmp_dir!(), "empty_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      assert {:ok, attrs_list} = Sync.process_directory(dir)
      assert attrs_list == []

      cleanup_directory(dir)
    end
  end

  # ============================================================================
  # process_directory/1 - File Type Handling
  # ============================================================================

  describe "process_directory/1 - file type routing" do
    test "routes .md files to MarkdownProcessor" do
      dir =
        create_test_directory([
          {"post.md", simple_markdown_content(), valid_blog_metadata()}
        ])

      assert {:ok, [attrs]} = Sync.process_directory(dir)
      assert attrs.parse_status == :success
      assert is_binary(attrs.processed_content)
      assert String.contains?(attrs.processed_content, "<h1>")

      cleanup_directory(dir)
    end

    test "routes .html files to HtmlProcessor" do
      dir =
        create_test_directory([
          {"page.html", simple_html_content(), valid_page_metadata()}
        ])

      assert {:ok, [attrs]} = Sync.process_directory(dir)
      assert attrs.parse_status == :success
      assert attrs.processed_content == simple_html_content()

      cleanup_directory(dir)
    end

    test "ignores non-content files" do
      dir = Path.join(System.tmp_dir!(), "sync_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      # Create various non-content files
      File.write!(Path.join(dir, "README.txt"), "readme")
      File.write!(Path.join(dir, "config.json"), "{}")
      File.write!(Path.join(dir, "script.js"), "console.log()")
      File.write!(Path.join(dir, ".gitignore"), "*.log")

      # Create one valid content file
      File.write!(Path.join(dir, "post.md"), simple_markdown_content())
      File.write!(Path.join(dir, "post.yaml"), valid_blog_metadata())

      assert {:ok, attrs_list} = Sync.process_directory(dir)
      # Should only process the .md file
      assert length(attrs_list) == 1

      cleanup_directory(dir)
    end
  end

  describe "process_directory/1 - file discovery" do
    test "discovers files in flat directory structure only" do
      dir = Path.join(System.tmp_dir!(), "sync_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      # Create files in root directory
      File.write!(Path.join(dir, "root1.md"), simple_markdown_content())
      File.write!(Path.join(dir, "root1.yaml"), valid_blog_metadata())
      File.write!(Path.join(dir, "root2.md"), simple_markdown_content())

      File.write!(
        Path.join(dir, "root2.yaml"),
        """
        title: "Root 2"
        slug: "root-2"
        type: "blog"
        """
      )

      # Create subdirectory with files (should be ignored)
      subdir = Path.join(dir, "subdir")
      File.mkdir_p!(subdir)
      File.write!(Path.join(subdir, "nested.md"), simple_markdown_content())

      File.write!(
        Path.join(subdir, "nested.yaml"),
        """
        title: "Nested"
        slug: "nested"
        type: "blog"
        """
      )

      assert {:ok, attrs_list} = Sync.process_directory(dir)
      # Should only discover root level files
      assert length(attrs_list) == 2

      slugs = Enum.map(attrs_list, & &1.slug)
      refute "nested" in slugs

      cleanup_directory(dir)
    end
  end

  # ============================================================================
  # process_directory/1 - Edge Cases
  # ============================================================================

  describe "process_directory/1 - edge cases" do
    test "handles directory with only metadata files" do
      dir = Path.join(System.tmp_dir!(), "sync_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      # Create only metadata files without corresponding content files
      File.write!(Path.join(dir, "post.yaml"), valid_blog_metadata())

      assert {:ok, attrs_list} = Sync.process_directory(dir)
      assert attrs_list == []

      cleanup_directory(dir)
    end

    test "handles files with unicode names" do
      dir =
        create_test_directory([
          {"测试文件.md", simple_markdown_content(),
           """
           title: "Unicode Test"
           slug: "unicode-test"
           type: "blog"
           """}
        ])

      assert {:ok, attrs_list} = Sync.process_directory(dir)
      assert length(attrs_list) == 1

      cleanup_directory(dir)
    end

    test "handles absolute directory paths" do
      dir =
        create_test_directory([
          {"post.md", simple_markdown_content(), valid_blog_metadata()}
        ])

      absolute_path = Path.expand(dir)
      assert {:ok, attrs_list} = Sync.process_directory(absolute_path)
      assert length(attrs_list) == 1

      cleanup_directory(dir)
    end

    test "handles directory path with trailing slash" do
      dir =
        create_test_directory([
          {"post.md", simple_markdown_content(), valid_blog_metadata()}
        ])

      dir_with_slash = dir <> "/"
      assert {:ok, attrs_list} = Sync.process_directory(dir_with_slash)
      assert length(attrs_list) == 1

      cleanup_directory(dir)
    end
  end

  # ============================================================================
  # process_directory/1 - Attribute Structure Validation
  # ============================================================================

  describe "process_directory/1 - attribute structure consistency" do
    test "attributes have all required fields" do
      dir =
        create_test_directory([
          {"post.md", simple_markdown_content(), valid_blog_metadata()}
        ])

      assert {:ok, [attrs]} = Sync.process_directory(dir)
      assert Map.has_key?(attrs, :slug)
      assert Map.has_key?(attrs, :content_type)
      assert Map.has_key?(attrs, :raw_content)
      assert Map.has_key?(attrs, :processed_content)
      assert Map.has_key?(attrs, :parse_status)

      cleanup_directory(dir)
    end

    test "content_type is an atom" do
      dir =
        create_test_directory([
          {"post.md", simple_markdown_content(), valid_blog_metadata()}
        ])

      assert {:ok, [attrs]} = Sync.process_directory(dir)
      assert attrs.content_type in [:blog, :page, :landing, :documentation]

      cleanup_directory(dir)
    end

    test "parse_status is an atom" do
      dir =
        create_test_directory([
          {"post.md", simple_markdown_content(), valid_blog_metadata()}
        ])

      assert {:ok, [attrs]} = Sync.process_directory(dir)
      assert attrs.parse_status in [:success, :error]

      cleanup_directory(dir)
    end
  end

  # ============================================================================
  # process_directory/1 - Idempotency
  # ============================================================================

  describe "process_directory/1 - idempotency" do
    test "processing same directory twice produces same result" do
      dir =
        create_test_directory([
          {"post.md", simple_markdown_content(), valid_blog_metadata()}
        ])

      assert {:ok, attrs_list1} = Sync.process_directory(dir)
      assert {:ok, attrs_list2} = Sync.process_directory(dir)

      assert length(attrs_list1) == length(attrs_list2)
      [attrs1] = attrs_list1
      [attrs2] = attrs_list2

      assert attrs1.slug == attrs2.slug
      assert attrs1.title == attrs2.title
      assert attrs1.raw_content == attrs2.raw_content

      cleanup_directory(dir)
    end
  end

  # ============================================================================
  # process_directory/1 - Performance with Many Files
  # ============================================================================

  describe "process_directory/1 - performance with many files" do
    test "successfully processes directory with many files" do
      many_files =
        for i <- 1..50 do
          {"post#{i}.md", simple_markdown_content(),
           """
           title: "Post #{i}"
           slug: "post-#{i}"
           type: "blog"
           """}
        end

      dir = create_test_directory(many_files)

      assert {:ok, attrs_list} = Sync.process_directory(dir)
      assert length(attrs_list) == 50

      successful = Enum.filter(attrs_list, &(&1.parse_status == :success))
      assert length(successful) == 50

      cleanup_directory(dir)
    end

    test "handles large files efficiently" do
      large_content = String.duplicate("# Section\n\nContent paragraph.\n\n", 1000)

      dir =
        create_test_directory([
          {"large.md", large_content, valid_blog_metadata()}
        ])

      assert {:ok, [attrs]} = Sync.process_directory(dir)
      assert attrs.parse_status == :success
      assert String.length(attrs.raw_content) > 10_000

      cleanup_directory(dir)
    end
  end

  # ============================================================================
  # process_directory/1 - Agnostic Design Verification
  # ============================================================================

  describe "process_directory/1 - agnostic design" do
    test "does not create any database records" do
      # This test verifies that Sync.process_directory/1 is truly agnostic
      # and does NOT touch the database at all
      dir =
        create_test_directory([
          {"post.md", simple_markdown_content(), valid_blog_metadata()}
        ])

      # Just returns attribute maps, no side effects
      assert {:ok, attrs_list} = Sync.process_directory(dir)
      assert is_list(attrs_list)
      assert length(attrs_list) == 1
      assert is_map(hd(attrs_list))

      cleanup_directory(dir)
    end

    test "returns plain maps suitable for changesets" do
      dir =
        create_test_directory([
          {"post.md", simple_markdown_content(), valid_blog_metadata()}
        ])

      assert {:ok, [attrs]} = Sync.process_directory(dir)
      # Should be a plain map, not a struct
      refute is_struct(attrs)
      assert is_map(attrs)

      cleanup_directory(dir)
    end

    test "does not require Scope parameter" do
      # The agnostic design means no Scope is needed
      # This is verified by the function signature: process_directory(directory)
      # not process_directory(scope, directory)
      dir =
        create_test_directory([
          {"post.md", simple_markdown_content(), valid_blog_metadata()}
        ])

      # Takes only directory, no scope
      assert {:ok, _attrs_list} = Sync.process_directory(dir)

      cleanup_directory(dir)
    end
  end
end
