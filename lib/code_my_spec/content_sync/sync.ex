defmodule CodeMySpec.ContentSync.Sync do
  @moduledoc """
  Agnostic content synchronization pipeline that processes filesystem content into attribute maps.

  Accepts a directory path, discovers content files (non-recursive), processes them through
  appropriate parsers and processors, and returns a list of attribute maps. These maps can be
  consumed by either Content or ContentAdmin changesets - the caller handles database operations.

  ## Philosophy

  Sync is the foundational layer that:
  - Reads files from filesystem
  - Parses metadata (YAML sidecar files)
  - Processes content (Markdown, HTML)
  - Returns generic attribute maps

  Sync does NOT:
  - Create database records
  - Handle multi-tenant scoping
  - Manage transactions
  - Broadcast events

  The caller decides how to use the attribute maps (Content for production, ContentAdmin for validation).

  ## Public API

      @spec process_directory(directory :: String.t()) :: {:ok, [content_attrs()]} | {:error, term()}

  ## Example

      iex> Sync.process_directory("/path/to/content")
      {:ok, [
        %{
          slug: "hello-world",
          title: "Hello World",
          content_type: :blog,
          content: "# Hello World\\n\\nWelcome...",
          processed_content: "<h1>Hello World</h1><p>Welcome...</p>",
          parse_status: :success,
          parse_errors: nil,
          # ... other attributes
        },
        %{
          slug: "about",
          title: "About Us",
          content_type: :page,
          # ...
        }
      ]}
  """

  alias CodeMySpec.ContentSync.{
    HtmlProcessor,
    MarkdownProcessor,
    MetaDataParser,
    ProcessorResult
  }

  @type content_attrs :: %{
          required(:slug) => String.t(),
          required(:content_type) => :blog | :page | :landing | :documentation,
          required(:raw_content) => String.t(),
          required(:processed_content) => String.t() | nil,
          required(:parse_status) => :success | :error,
          optional(:parse_errors) => map() | nil,
          optional(:title) => String.t(),
          optional(:protected) => boolean(),
          optional(:publish_at) => DateTime.t(),
          optional(:expires_at) => DateTime.t(),
          optional(:meta_title) => String.t(),
          optional(:meta_description) => String.t(),
          optional(:og_image) => String.t(),
          optional(:og_title) => String.t(),
          optional(:og_description) => String.t(),
          optional(:metadata) => map()
        }

  @doc """
  Processes a directory of content files and returns attribute maps.

  ## Parameters

    - `directory` - Absolute path to the directory containing content files

  ## Returns

    - `{:ok, [content_attrs]}` - List of attribute maps ready for changesets
    - `{:error, :invalid_directory}` - Directory doesn't exist or isn't readable

  ## Processing Steps

  1. Validates directory exists and is readable
  2. Discovers content files (*.md, *.html) in flat directory structure
  3. For each file:
     - Reads file contents
     - Parses metadata from sidecar .yaml file
     - Routes to appropriate processor based on extension
     - Merges metadata + processed content into attribute map
     - Captures parse errors in parse_status/parse_errors fields
  4. Returns list of attribute maps

  ## Error Handling

  Individual file parse errors do NOT fail the entire operation. Files with parse errors
  will have `parse_status: :error` and `parse_errors: %{...}` in their attribute maps.

  ## Examples

      iex> process_directory("/path/to/content")
      {:ok, [%{slug: "post-1", ...}, %{slug: "post-2", ...}]}

      iex> process_directory("/nonexistent")
      {:error, :invalid_directory}

  ## Usage with Content (single-tenant production)

      {:ok, attrs_list} = Sync.process_directory("/path/to/content")

      Repo.transaction(fn ->
        Content.delete_all_content()

        Enum.each(attrs_list, fn attrs ->
          # Filter attrs to only Content fields
          content_attrs = Map.take(attrs, [:slug, :title, :content_type, :content, ...])
          Content.create_content(content_attrs)
        end)
      end)

  ## Usage with ContentAdmin (multi-tenant validation)

      {:ok, attrs_list} = Sync.process_directory("/path/to/content")

      Repo.transaction(fn ->
        ContentAdmin.delete_all_content(scope)

        Enum.each(attrs_list, fn attrs ->
          # Add multi-tenant scoping
          admin_attrs = Map.merge(attrs, %{
            account_id: scope.active_account_id,
            project_id: scope.active_project_id
          })
          ContentAdmin.create_content_admin(scope, admin_attrs)
        end)
      end)
  """
  @spec process_directory(String.t()) :: {:ok, [content_attrs()]} | {:error, term()}
  def process_directory(directory) do
    require Logger

    with :ok <- validate_directory(directory) do
      {file_paths, skipped_paths} = discover_files(directory)

      skipped_attrs = Enum.map(skipped_paths, &build_missing_metadata_attrs/1)
      processed_attrs = Enum.map(file_paths, &process_file/1)

      {:ok, processed_attrs ++ skipped_attrs}
    end
  end

  # ============================================================================
  # Directory Validation
  # ============================================================================

  @spec validate_directory(String.t() | nil) :: :ok | {:error, :invalid_directory}
  defp validate_directory(nil), do: {:error, :invalid_directory}
  defp validate_directory(""), do: {:error, :invalid_directory}

  defp validate_directory(directory) when is_binary(directory) do
    cond do
      not File.exists?(directory) ->
        {:error, :invalid_directory}

      not File.dir?(directory) ->
        {:error, :invalid_directory}

      true ->
        case File.stat(directory) do
          {:ok, %File.Stat{access: access}} when access in [:read, :read_write] ->
            :ok

          {:ok, _stat} ->
            {:error, :invalid_directory}

          {:error, _reason} ->
            {:error, :invalid_directory}
        end
    end
  end

  # ============================================================================
  # File Discovery
  # ============================================================================

  @spec discover_files(String.t()) :: {[String.t()], [String.t()]}
  defp discover_files(directory) do
    patterns = [
      Path.join(directory, "*.md"),
      Path.join(directory, "*.html")
    ]

    all_files =
      patterns
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.uniq()
      |> Enum.sort()

    {with_meta, without_meta} = Enum.split_with(all_files, &has_metadata_file?/1)
    {with_meta, without_meta}
  end

  @spec has_metadata_file?(String.t()) :: boolean()
  defp has_metadata_file?(file_path) do
    metadata_path = Path.rootname(file_path) <> ".yaml"
    File.exists?(metadata_path)
  end

  # ============================================================================
  # File Processing
  # ============================================================================

  @sobelow_skip ["Traversal.FileModule"]
  @spec process_file(String.t()) :: content_attrs()
  defp process_file(file_path) do
    raw_content = File.read!(file_path)
    extension = Path.extname(file_path)
    metadata_path = Path.rootname(file_path) <> ".yaml"

    case MetaDataParser.parse_metadata_file(metadata_path) do
      {:ok, metadata} ->
        processor_result = route_to_processor(extension, raw_content)
        merge_metadata_and_result(metadata, processor_result, raw_content)

      {:error, error_detail} ->
        build_metadata_error_attrs(raw_content, error_detail)
    end
  end

  @spec route_to_processor(String.t(), String.t()) :: ProcessorResult.t()
  defp route_to_processor(".md", raw_content) do
    {:ok, result} = MarkdownProcessor.process(raw_content)
    result
  end

  defp route_to_processor(".html", raw_content) do
    {:ok, result} = HtmlProcessor.process(raw_content)
    result
  end

  @sobelow_skip ["Traversal.FileModule"]
  defp build_missing_metadata_attrs(path) do
    require Logger
    filename = Path.basename(path)
    Logger.warning("ContentSync: Skipping #{filename} — no YAML metadata sidecar file")

    %{
      slug: Path.rootname(filename),
      content_type: :blog,
      raw_content: File.read!(path),
      processed_content: nil,
      parse_status: :error,
      parse_errors: %{
        error_type: "MissingMetadata",
        message: "No YAML sidecar file found for #{filename}. Create #{Path.rootname(filename)}.yaml alongside it."
      },
      metadata: %{}
    }
  end

  @spec merge_metadata_and_result(map(), ProcessorResult.t(), String.t()) :: content_attrs()
  defp merge_metadata_and_result(metadata, %ProcessorResult{} = result, raw_content) do
    # Base attrs are always present (even when nil)
    base_attrs = %{
      slug: metadata[:slug],
      title: metadata[:title],
      content_type: atomize_content_type(metadata[:type]),
      raw_content: raw_content,
      processed_content: result.processed_content,
      parse_status: result.parse_status,
      parse_errors: atomize_parse_errors(result.parse_errors),
      metadata: stringify_keys(metadata)
    }

    # Optional attrs - only include when not nil
    optional_attrs =
      %{
        publish_at: parse_datetime(metadata[:publish_at]),
        expires_at: parse_datetime(metadata[:expires_at]),
        meta_title: metadata[:meta_title],
        meta_description: metadata[:meta_description],
        og_image: metadata[:og_image],
        og_title: metadata[:og_title],
        og_description: metadata[:og_description],
        protected: metadata[:protected]
      }
      |> reject_nil_values()

    Map.merge(base_attrs, optional_attrs)
  end

  @spec build_metadata_error_attrs(String.t(), map()) :: content_attrs()
  defp build_metadata_error_attrs(raw_content, error_detail) do
    %{
      slug: generate_error_slug(),
      content_type: :blog,
      raw_content: raw_content,
      processed_content: nil,
      parse_status: :error,
      parse_errors: %{
        error_type: "MetaDataParseError",
        message:
          Map.get(error_detail, :message) || Map.get(error_detail, "message") || "Unknown error",
        details: serialize_error_detail(error_detail)
      },
      metadata: %{}
    }
  end

  @spec serialize_error_detail(map()) :: map()
  defp serialize_error_detail(error_detail) when is_map(error_detail) do
    # Convert any nested structs to maps
    Enum.reduce(error_detail, %{}, fn {key, value}, acc ->
      Map.put(acc, key, serialize_value(value))
    end)
  end

  defp serialize_value(%YamlElixir.ParsingError{} = error) do
    %{
      line: error.line,
      column: error.column,
      type: error.type,
      message: error.message
    }
  end

  defp serialize_value(value) when is_struct(value) do
    Map.from_struct(value)
  end

  defp serialize_value(value), do: value

  @spec atomize_parse_errors(map() | nil) :: map() | nil
  defp atomize_parse_errors(nil), do: nil
  defp atomize_parse_errors(errors) when is_map(errors), do: errors

  @spec generate_error_slug() :: String.t()
  defp generate_error_slug do
    "error-" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
  end

  @spec atomize_content_type(String.t() | nil) :: atom()
  defp atomize_content_type("blog"), do: :blog
  defp atomize_content_type("page"), do: :page
  defp atomize_content_type("landing"), do: :landing
  defp atomize_content_type("documentation"), do: :documentation
  defp atomize_content_type(_), do: :blog

  @spec parse_datetime(String.t() | DateTime.t() | nil) :: DateTime.t() | nil
  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime(string) when is_binary(string) do
    case DateTime.from_iso8601(string) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> nil
    end
  end

  defp parse_datetime(_), do: nil

  @spec reject_nil_values(map()) :: map()
  defp reject_nil_values(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  @spec stringify_keys(map()) :: map()
  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), json_safe_value(value)}
      {key, value} -> {to_string(key), json_safe_value(value)}
    end)
  end

  # Ensure values are JSON-encodable (no tuples, structs, etc.)
  defp json_safe_value(value) when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp json_safe_value(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe_value(value) when is_tuple(value), do: inspect(value)
  defp json_safe_value(%Date{} = d), do: Date.to_iso8601(d)
  defp json_safe_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp json_safe_value(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
  defp json_safe_value(value) when is_struct(value), do: inspect(value)
  defp json_safe_value(value) when is_map(value), do: stringify_keys(value)
  defp json_safe_value(value) when is_list(value), do: Enum.map(value, &json_safe_value/1)
  defp json_safe_value(value), do: inspect(value)
end
