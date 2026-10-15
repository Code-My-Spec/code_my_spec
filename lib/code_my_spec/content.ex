defmodule CodeMySpec.Content do
  @moduledoc """
  Published content for public and authenticated viewing.

  Serves blog posts, pages, landing pages and documentation to end users.
  Content is single-tenant (no account_id/project_id); access control is by
  authentication, not tenancy:

  - **With %Scope{}**: authenticated → public and protected content
  - **With nil**: anonymous → public content only (`protected = false`)

  Content is written only by `sync_content/1`, which replaces everything. It is
  reached from `/api/content/sync` and from `Content.Pull`, which a deployed
  client runs when `ContentPublishing.publish/1` triggers it.
  """

  use Boundary,
    top_level?: true,
    deps: [CodeMySpec.Repo, CodeMySpec.Users.Scope, CodeMySpec.Utils],
    exports: :all

  import Ecto.Query, warn: false

  require Logger

  alias CodeMySpec.Content.{Content, ContentRepository, ContentTag, Tag}
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @type content_type :: :blog | :page | :landing | :documentation

  # Content Retrieval

  @doc """
  Returns all published content for a given content type.

  Content is considered published when:
  - publish_at is in the past or nil
  - expires_at is in the future or nil

  ## Parameters
    - scope_or_nil: %Scope{} for authenticated users (access to protected content), nil for anonymous (public only)
    - content_type: `:blog`, `:page`, `:landing` or `:documentation`

  ## Examples

      # Anonymous user - only public content
      Content.list_published_content(nil, :blog)

      # Authenticated user - public AND protected content
      Content.list_published_content(scope, :blog)
  """
  @spec list_published_content(Scope.t() | nil, content_type()) :: [Content.t()]
  def list_published_content(scope_or_nil, content_type) do
    ContentRepository.list_published_content(scope_or_nil, content_type)
  end

  @doc """
  Gets content by slug and content type.

  Returns nil if not found or if content is protected and scope is nil.

  ## Parameters
    - scope_or_nil: %Scope{} for authenticated users, nil for anonymous
    - slug: String slug identifier
    - content_type: `:blog`, `:page`, `:landing` or `:documentation`

  ## Examples

      # Try to get public content (anonymous)
      Content.get_content_by_slug(nil, "my-post", :blog)

      # Get any published content (authenticated)
      Content.get_content_by_slug(scope, "my-post", :blog)
  """
  @spec get_content_by_slug(Scope.t() | nil, String.t(), content_type()) :: Content.t() | nil
  def get_content_by_slug(scope_or_nil, slug, content_type) do
    ContentRepository.get_content_by_slug(scope_or_nil, slug, content_type)
  end

  @doc """
  Gets content by slug and content type.

  With %Scope{}: Raises Ecto.NoResultsError if not found.
  With nil: Returns nil if not found (non-raising for anonymous users).

  ## Parameters
    - scope_or_nil: %Scope{} for authenticated users, nil for anonymous
    - slug: String slug identifier
    - content_type: `:blog`, `:page`, `:landing` or `:documentation`

  ## Examples

      # Authenticated - raises if not found
      Content.get_content_by_slug!(scope, "my-post", :blog)

      # Anonymous - returns nil if not found (non-raising)
      Content.get_content_by_slug!(nil, "my-post", :blog)
  """
  @spec get_content_by_slug!(Scope.t() | nil, String.t(), content_type()) :: Content.t() | nil
  def get_content_by_slug!(scope_or_nil, slug, content_type) do
    ContentRepository.get_content_by_slug!(scope_or_nil, slug, content_type)
  end

  # Content Sync (Publishing Flow)

  @doc """
  Replaces all content with `content_list`, in one transaction.

  Any invalid row is logged and rolls the whole sync back, leaving existing
  content intact.

  ## Parameters
    - content_list: List of content maps with all fields (slug, title, content_type, processed_content, etc.)

  ## Examples

      Content.sync_content([
        %{slug: "post-1", title: "Post 1", content_type: "blog", processed_content: "<h1>Post 1</h1>", ...},
        %{slug: "post-2", title: "Post 2", content_type: "blog", processed_content: "<h1>Post 2</h1>", ...}
      ])
  """
  @spec sync_content([map()]) :: {:ok, [Content.t()]} | {:error, term()}
  def sync_content(content_list) do
    require Logger

    Repo.transaction(fn ->
      {deleted_count, _} = Repo.delete_all(Content)
      Logger.info("Deleted #{deleted_count} existing content records")

      changesets =
        Enum.with_index(content_list, fn attrs, index ->
          changeset = Content.changeset(%Content{}, attrs)
          {changeset, index}
        end)

      changesets
      |> Enum.filter(fn {cs, _index} -> not cs.valid? end)
      |> Enum.each(&log_invalid_changeset/1)

      case Enum.find(changesets, fn {cs, _index} -> not cs.valid? end) do
        nil -> insert_valid_content(changesets)
        {invalid_changeset, index} -> abort_sync_content(invalid_changeset, index)
      end
    end)
  end

  defp insert_valid_content(changesets) do
    content_records = Enum.map(changesets, fn {changeset, _index} -> Repo.insert!(changeset) end)
    Logger.info("Created #{length(content_records)} new content records")
    content_records
  end

  defp abort_sync_content(invalid_changeset, index) do
    Logger.error("Aborting sync_content due to validation failure at index #{index}")
    Repo.rollback(invalid_changeset)
  end

  @doc """
  Deletes all content.

  ## Examples

      Content.delete_all_content()
      # => {:ok, 42}
  """
  @spec delete_all_content() :: {:ok, integer()}
  def delete_all_content do
    {count, _} = Repo.delete_all(Content)
    {:ok, count}
  end

  # Tag Management

  @doc """
  Returns all tags.

  No scoping - returns all tags in the system.

  ## Examples

      Content.list_all_tags()
      # => [%Tag{name: "elixir", slug: "elixir"}, ...]
  """
  @spec list_all_tags() :: [Tag.t()]
  def list_all_tags do
    Repo.all(Tag)
  end

  @doc """
  Returns all tags associated with the given content.

  ## Parameters
    - content: Content struct

  ## Examples

      content = Content.get_content_by_slug(scope, "my-post", :blog)
      Content.get_content_tags(content)
      # => [%Tag{name: "elixir", slug: "elixir"}, ...]
  """
  @spec get_content_tags(Content.t()) :: [Tag.t()]
  def get_content_tags(%Content{} = content) do
    content
    |> ContentRepository.preload_tags()
    |> Map.get(:tags)
  end

  @doc """
  Creates or returns existing tag with the given name.

  Generates slug from name automatically.

  ## Parameters
    - name: String tag name

  ## Examples

      Content.upsert_tag("Elixir")
      # => {:ok, %Tag{name: "Elixir", slug: "elixir"}}
  """
  @spec upsert_tag(String.t()) :: {:ok, Tag.t()} | {:error, Ecto.Changeset.t()}
  def upsert_tag(name) do
    slug = slugify(name)

    case Repo.get_by(Tag, slug: slug) do
      nil ->
        %Tag{}
        |> Tag.changeset(%{name: name, slug: slug})
        |> Repo.insert()

      tag ->
        {:ok, tag}
    end
  end

  defp slugify(string) do
    string
    |> String.downcase()
    |> String.replace(~r/[^\w\s-]/, "")
    |> String.replace(~r/\s+/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end

  @doc """
  Synchronizes tags for content.

  Removes old tag associations and creates new ones.

  ## Parameters
    - content: Content struct
    - tag_names: List of tag name strings

  ## Examples

      content = Content.get_content_by_slug(scope, "my-post", :blog)
      Content.sync_content_tags(content, ["elixir", "phoenix", "liveview"])
      # => {:ok, %Content{tags: [...]}}
  """
  @spec sync_content_tags(Content.t(), [String.t()]) :: {:ok, Content.t()} | {:error, term()}
  def sync_content_tags(%Content{} = content, tag_names) do
    Repo.transaction(fn ->
      ContentTag
      |> where([ct], ct.content_id == ^content.id)
      |> Repo.delete_all()

      tag_names
      |> Enum.map(fn name ->
        {:ok, tag} = upsert_tag(name)
        tag
      end)
      |> Enum.each(fn tag ->
        %ContentTag{}
        |> ContentTag.changeset(%{content_id: content.id, tag_id: tag.id})
        |> Repo.insert!()
      end)

      content
      |> Repo.reload!()
      |> ContentRepository.preload_tags()
    end)
  end

  defp log_invalid_changeset({cs, index}) do
    errors = Ecto.Changeset.traverse_errors(cs, &interpolate_error/1)
    title = Map.get(cs.changes, :title, "untitled")
    error_string = CodeMySpec.Utils.changeset_error_to_string(cs)

    Logger.error(
      "Content validation failed at index #{index}: #{title} - #{error_string}",
      changeset_errors: errors,
      changeset_changes: cs.changes,
      index: index
    )
  end

  defp interpolate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end
end
