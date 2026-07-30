defmodule CodeMySpec.ContentPublishing do
  @moduledoc """
  Local-first content publishing (story 712).

  Parses markdown the user points at on disk — any directory, no git — into a
  per-project snapshot, rewrites image refs to the project's CDN host, and
  (on publish) uploads images + a content blob + manifest to the user's own S3
  buckets before triggering the deployed client to pull.

  The snapshot is staged in the `content_admin` table, scoped by
  `scope.active_project_id` (the local scope from `Scope.for_local_project/1`
  carries only `active_account_id`/`active_project_id`, not loaded structs —
  so we query by id, never `scope.active_account.id`).
  """

  import Ecto.Query, warn: false

  alias CodeMySpec.Content.CloudflareClient
  alias CodeMySpec.Content.Content, as: PublishedContent
  alias CodeMySpec.Content.S3Client
  alias CodeMySpec.Content.TriggerClient
  alias CodeMySpec.ContentPublishing.FrontmatterParser
  alias CodeMySpec.ContentPublishing.ImageAsset
  alias CodeMySpec.ContentPublishing.Snapshot
  alias CodeMySpec.Environments
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @type counts :: %{success: non_neg_integer(), error: non_neg_integer()}

  @image_extensions ~w(.webp .png .jpg .jpeg .gif .svg .avif)

  @doc """
  Parse every markdown file under the project's content source directory into
  the local snapshot, replacing any prior snapshot for this project.

  Reads straight from `scope.environment` — no clone/fetch/pull. A single
  malformed file lands as a `parse_status: :error` row; the sync never aborts.
  Returns `{:ok, counts}` or `{:error, :no_source_path}` when no source is set.
  """
  @spec sync(Scope.t()) :: {:ok, counts()} | {:error, :no_source_path}
  def sync(%Scope{} = scope) do
    project = scope.active_project

    case project && project.content_source_path do
      nil ->
        {:error, :no_source_path}

      "" ->
        {:error, :no_source_path}

      source_path ->
        rows =
          scope
          |> content_files(source_path)
          |> Enum.map(&parse_file(scope, &1, project.images_host))

        replace_snapshot(scope, rows)
        image_counts = sync_images(scope, project, source_path)
        {:ok, Map.merge(count_rows(rows), image_counts)}
    end
  end

  @doc """
  Build and ship the published content from the current snapshot (story 712,
  criteria 6274-6276).

  Refuses if any snapshot row has `parse_status: :error` — naming the offending
  file — writing nothing to S3 and triggering no client. Otherwise writes a
  content blob + integrity manifest to the project's content bucket and POSTs
  a pull trigger to the deployed client.
  """
  @spec publish(Scope.t()) :: {:ok, map()} | {:error, map()}
  def publish(%Scope{} = scope) do
    project = scope.active_project
    rows = list_snapshot(scope)

    case Enum.find(rows, &(&1.parse_status == :error)) do
      %Snapshot{} = bad ->
        {:error,
         %{message: "Cannot publish: #{bad.metadata["filename"]} has parse errors — re-sync clean first"}}

      nil ->
        do_publish(project, Enum.filter(rows, &(&1.parse_status == :success)))
    end
  end

  defp do_publish(project, success_rows) do
    bucket = project.content_bucket
    creds = aws_credentials(project)
    blob_json = success_rows |> Enum.map(&blob_row/1) |> Jason.encode!()
    blob_url = "https://#{bucket}/content.json"
    manifest_url = "https://#{bucket}/manifest.json"
    counts = counts_by_type(success_rows)

    manifest = %{
      "version" => "1.0",
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "content_blob_url" => blob_url,
      "content_blob_hash" => "sha256:" <> hex(:crypto.hash(:sha256, blob_json)),
      "counts" => counts
    }

    with :ok <-
           S3Client.put_object(bucket, "content.json", blob_json,
             content_type: "application/json",
             credentials: creds
           ),
         :ok <-
           S3Client.put_object(bucket, "manifest.json", Jason.encode!(manifest),
             content_type: "application/json",
             credentials: creds
           ),
         {:ok, result} <- trigger_client(project, manifest_url) do
      {:ok, Map.merge(result, %{counts: counts, total: length(success_rows)})}
    else
      {:error, %{message: _} = err} -> {:error, err}
      {:error, reason} -> {:error, %{message: "S3 write failed: #{inspect(reason)}"}}
    end
  end

  defp trigger_client(%{client_api_url: url, deploy_key: key}, manifest_url)
       when is_binary(url) and url != "" and is_binary(key) and key != "" do
    case TriggerClient.trigger(url, key, manifest_url) do
      {:ok, %{sync_id: sync_id}} ->
        {:ok, %{sync_id: sync_id, manifest_url: manifest_url}}

      {:error, reason} ->
        {:error, %{message: "Client pull trigger failed: #{inspect(reason)}"}}
    end
  end

  # An unconfigured trigger is a failure, not a quiet success. Sync is
  # trigger-only — no reconciliation pass, no retry sweep, nothing that later
  # notices the deployed site is stale — so a publish that never triggers does
  # not converge later. The content sits in the bucket permanently while the
  # operator has been told it worked. Issue bb956e54; story 972 criterion 8058
  # ("a lost trigger is reported, not swallowed") covers the same outcome
  # reached by a trigger that was never attempted rather than one that failed
  # in flight.
  defp trigger_client(project, _manifest_url) do
    missing =
      [:client_api_url, :deploy_key]
      |> Enum.filter(fn field -> Map.get(project, field) in [nil, ""] end)

    {:error,
     %{
       message:
         "Client pull trigger not configured — #{Enum.join(missing, ", ")} missing. " <>
           "Sync is trigger-only, so nothing would tell the site to pull this content."
     }}
  end

  # The project's own AWS keys (encrypted at rest), passed per-request to ExAws
  # so a published install signs uploads without a global `:ex_aws` env. Blank
  # entries are dropped so ExAws falls back to its app-env/default config.
  defp aws_credentials(project) do
    [
      access_key_id: project.aws_access_key_id,
      secret_access_key: project.aws_secret_access_key,
      region: project.aws_region
    ]
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
  end

  defp blob_row(%Snapshot{} = row), do: content_attrs(row.metadata || %{}, row.processed_content)

  # The published-content row shape, built from parsed metadata + rendered body.
  # Shared by the publish blob and the at-sync schema validation.
  defp content_attrs(meta, processed_content) do
    %{
      "slug" => meta["slug"],
      "title" => meta["title"],
      "content_type" => meta["content_type"],
      "processed_content" => processed_content,
      "publish_at" => meta["publish_at"],
      "expires_at" => meta["expires_at"],
      "protected" => meta["protected"] || false,
      "tags" => meta["tags"] || [],
      "meta_title" => meta["meta_title"],
      "meta_description" => meta["meta_description"],
      "og_title" => meta["og_title"],
      "og_description" => meta["og_description"],
      "og_image" => meta["og_image"],
      "metadata" => meta["metadata"] || %{}
    }
  end

  defp validate_against_schema(metadata, processed_content) do
    changeset = PublishedContent.changeset(%PublishedContent{}, content_attrs(metadata, processed_content))

    if changeset.valid? do
      :ok
    else
      errors =
        Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
          Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
        end)

      {:error, errors}
    end
  end

  defp counts_by_type(rows) do
    rows
    |> Enum.frequencies_by(fn row -> row.metadata["content_type"] end)
    |> Map.new(fn {type, count} -> {to_string(type), count} end)
  end

  @doc "All snapshot rows for the active project, oldest first."
  @spec list_snapshot(Scope.t()) :: [Snapshot.t()]
  def list_snapshot(%Scope{} = scope) do
    Snapshot
    |> where([c], c.project_id == ^scope.active_project_id)
    |> order_by([c], asc: c.id)
    |> Repo.all()
  end

  @doc """
  A single snapshot row for the active project, or nil. Tolerates a non-integer
  id (e.g. a slug in the URL) by returning nil instead of raising
  `Ecto.Query.CastError`.
  """
  @spec get_snapshot(Scope.t(), integer() | String.t()) :: Snapshot.t() | nil
  def get_snapshot(%Scope{} = scope, id) do
    case normalize_id(id) do
      nil ->
        nil

      int_id ->
        Snapshot
        |> where([c], c.project_id == ^scope.active_project_id)
        |> Repo.get(int_id)
    end
  end

  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp normalize_id(_), do: nil

  @doc "Success/error counts for the active project's snapshot."
  @spec counts(Scope.t()) :: counts()
  def counts(%Scope{} = scope) do
    scope
    |> list_snapshot()
    |> count_rows()
  end

  @doc "Timestamp of the most recent snapshot write, or nil if never synced."
  @spec last_synced_at(Scope.t()) :: DateTime.t() | nil
  def last_synced_at(%Scope{} = scope) do
    Snapshot
    |> where([c], c.project_id == ^scope.active_project_id)
    |> select([c], max(c.updated_at))
    |> Repo.one()
  end

  # -- internals --

  defp content_files(scope, source_path) do
    scope
    |> all_files(source_path)
    |> Enum.filter(&(Path.extname(&1) in [".md", ".html"]))
  end

  defp all_files(scope, source_path) do
    case Environments.glob(scope.environment, Path.join(source_path, "**/*")) do
      {:ok, paths} -> paths
      paths when is_list(paths) -> paths
      _ -> []
    end
  end

  # -- image upload + Cloudflare purge (criteria 6271, 6273) --

  defp sync_images(_scope, %{image_bucket: bucket}, _source) when bucket in [nil, ""] do
    %{images_synced: 0, images_failed: 0}
  end

  defp sync_images(scope, project, source_path) do
    images =
      scope
      |> all_files(source_path)
      |> Enum.filter(&(Path.extname(&1) in @image_extensions))

    {synced, failed, purge_urls} =
      Enum.reduce(images, {0, 0, []}, fn path, {synced, failed, purge} ->
        upload_image(scope, project, path, {synced, failed, purge})
      end)

    if purge_urls != [], do: CloudflareClient.purge(Enum.reverse(purge_urls))
    %{images_synced: synced, images_failed: failed}
  end

  defp upload_image(scope, project, path, {synced, failed, purge}) do
    key = Path.basename(path)

    case read(scope, path) do
      nil ->
        {synced, failed + 1, purge}

      bytes ->
        hash = hex(:crypto.hash(:sha256, bytes))
        changed? = image_changed?(scope, key, hash)

        case S3Client.put_object(project.image_bucket, key, bytes,
               content_type: content_type_for(key),
               credentials: aws_credentials(project)
             ) do
          :ok ->
            upsert_image(scope, key, hash)
            {synced + 1, failed, maybe_purge(purge, changed?, project.images_host, key)}

          {:error, _reason} ->
            {synced, failed + 1, purge}
        end
    end
  end

  defp maybe_purge(purge, true, images_host, key) when is_binary(images_host) do
    ["#{String.trim_trailing(images_host, "/")}/#{key}" | purge]
  end

  defp maybe_purge(purge, _changed?, _images_host, _key), do: purge

  defp image_changed?(scope, key, hash) do
    case Repo.get_by(ImageAsset, project_id: scope.active_project_id, key: key) do
      %ImageAsset{content_hash: ^hash} -> false
      %ImageAsset{} -> true
      nil -> false
    end
  end

  defp upsert_image(scope, key, hash) do
    %ImageAsset{}
    |> ImageAsset.changeset(%{project_id: scope.active_project_id, key: key, content_hash: hash})
    |> Repo.insert(
      on_conflict: [set: [content_hash: hash, updated_at: DateTime.utc_now(:second)]],
      conflict_target: [:project_id, :key]
    )
  end

  defp content_type_for(key) do
    case Path.extname(key) do
      ".webp" -> "image/webp"
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".svg" -> "image/svg+xml"
      ".avif" -> "image/avif"
      _ -> "application/octet-stream"
    end
  end

  defp hex(bin), do: Base.encode16(bin, case: :lower)

  defp parse_file(scope, path, images_host) do
    filename = path |> Path.basename() |> Path.rootname()
    format = FrontmatterParser.format_for(path)
    raw = read(scope, path)

    base = %{
      project_id: scope.active_project_id,
      raw_content: raw || ""
    }

    case raw && FrontmatterParser.parse(raw, format) do
      {:ok, meta, body} ->
        metadata = build_metadata(meta, filename)
        processed = render_body(body, format, images_host)

        # Validate against the published Content schema now (story 712,
        # criterion 6269), so a bad field surfaces as a per-file parse error
        # here rather than silently rolling back the client's atomic persist.
        case validate_against_schema(metadata, processed) do
          :ok ->
            Map.merge(base, %{
              parse_status: :success,
              parse_errors: nil,
              processed_content: processed,
              metadata: metadata
            })

          {:error, errors} ->
            Map.merge(base, %{
              parse_status: :error,
              parse_errors: %{type: :schema_validation, message: "Content schema validation failed", errors: errors},
              processed_content: nil,
              metadata: metadata
            })
        end

      {:error, detail} ->
        Map.merge(base, %{
          parse_status: :error,
          parse_errors: detail,
          processed_content: nil,
          metadata: %{"filename" => filename, "slug" => filename}
        })

      _ ->
        Map.merge(base, %{
          parse_status: :error,
          parse_errors: %{type: :read_error, message: "Could not read #{path}"},
          processed_content: nil,
          metadata: %{"filename" => filename, "slug" => filename}
        })
    end
  end

  defp build_metadata(meta, filename) do
    content_type = meta["content_type"] || meta["type"]

    meta
    |> Map.put("filename", filename)
    |> Map.put_new("slug", filename)
    |> maybe_put("content_type", content_type)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp read(scope, path) do
    case Environments.read_file(scope.environment, path) do
      {:ok, content} -> content
      _ -> nil
    end
  end

  # Produce the stored HTML: markdown bodies are image-rewritten then rendered
  # via Earmark (Windows-safe, unlike the MDEx NIF); HTML bodies are
  # image-rewritten and passed through. Either way `processed_content` is HTML,
  # which is what the blog templates `raw/1`.
  # CTA shortcodes expand before Earmark runs, so the result is plain HTML in
  # `processed_content`: crawler-visible, no JS, and it works on the blog's dead
  # views. See `CodeMySpec.ContentPublishing.Ctas`.
  defp render_body(body, :markdown, images_host) do
    body
    |> CodeMySpec.ContentPublishing.Ctas.expand()
    |> rewrite_markdown_images(images_host)
    |> markdown_to_html()
  end

  defp render_body(body, :html, images_host) do
    body
    |> CodeMySpec.ContentPublishing.Ctas.expand()
    |> rewrite_html_images(images_host)
  end

  defp markdown_to_html(markdown) do
    Earmark.as_html!(markdown, %Earmark.Options{compact_output: true, breaks: true, gfm: true})
  end

  defp rewrite_markdown_images(body, images_host) when is_binary(images_host) and images_host != "" do
    host = String.trim_trailing(images_host, "/")

    Regex.replace(~r/!\[([^\]]*)\]\(([^)]+)\)/, body, fn whole, alt, url ->
      if Regex.match?(~r{^https?://}, url),
        do: whole,
        else: "![#{alt}](#{host}/#{Path.basename(url)})"
    end)
  end

  defp rewrite_markdown_images(body, _images_host), do: body

  defp rewrite_html_images(body, images_host) when is_binary(images_host) and images_host != "" do
    host = String.trim_trailing(images_host, "/")

    Regex.replace(~r/(<img\b[^>]*?\bsrc=")([^"]+)(")/i, body, fn whole, pre, url, post ->
      if Regex.match?(~r{^https?://}, url),
        do: whole,
        else: "#{pre}#{host}/#{Path.basename(url)}#{post}"
    end)
  end

  defp rewrite_html_images(body, _images_host), do: body

  defp replace_snapshot(scope, rows) do
    Repo.transaction(fn ->
      Snapshot
      |> where([c], c.project_id == ^scope.active_project_id)
      |> Repo.delete_all()

      Enum.each(rows, fn attrs ->
        %Snapshot{}
        |> Snapshot.changeset(attrs)
        |> Repo.insert!()
      end)
    end)
  end

  defp count_rows(rows) do
    Enum.reduce(rows, %{success: 0, error: 0}, fn row, acc ->
      case parse_status(row) do
        :success -> %{acc | success: acc.success + 1}
        :error -> %{acc | error: acc.error + 1}
        _ -> acc
      end
    end)
  end

  defp parse_status(%Snapshot{parse_status: status}), do: status
  defp parse_status(%{parse_status: status}), do: status
end
