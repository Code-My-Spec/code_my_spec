defmodule CodeMySpec.Provisioning.Storage do
  @moduledoc """
  Object storage in the user's own Hetzner account — buckets, retention, and
  the dumps that land in them.

  - **The buckets are the user's.** Every call signs with the project's own
    credentials against their account, so the resources survive us;
    `owner: "user"` on each recorded resource makes that checkable.
  - **One bucket per environment** (`bucket_name/2`), so a UAT test upload
    can never sit beside real customer data.
  - **Retention is a bucket lifecycle rule** (`put_lifecycle/4`), not a
    pruning job that one broken cron turns into an ever-growing bill.
  - **Credentials** are never minted here (Hetzner has no API for S3 keys);
    the `storage` step pauses for them and re-verifies on resume.

  See knowledge/provisioning, "Storage".
  """

  alias CodeMySpec.Provisioning.Wait

  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Users.Scope

  require Logger

  # Hetzner's object storage speaks S3 per location; the location is both the
  # host and the signing region.
  @default_location "fsn1"

  @type credentials :: [
          access_key_id: String.t(),
          secret_access_key: String.t(),
          region: String.t()
        ]

  @doc """
  The bucket for one environment of one project.

  Bucket names are DNS-shaped and unique, so this lowercases and strips
  anything S3 will not take; project names are free text.

  ## Examples

      iex> CodeMySpec.Provisioning.Storage.bucket_name(%{name: "My App!"}, "prod")
      "my-app-prod"
  """
  @spec bucket_name(map() | struct(), String.t()) :: String.t()
  def bucket_name(project, environment) do
    base =
      case field(project, :name) do
        name when is_binary(name) and name != "" ->
          name
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9-]+/, "-")
          |> String.trim("-")

        _ ->
          # No generic fallback: bucket names are unique per account, so two
          # unnamed projects would share one bucket.
          raise ArgumentError,
                "cannot derive a bucket name: #{inspect(project)} has no name"
      end

    "#{base}-#{environment}"
  end

  # Ecto structs do not implement Access; tests pass plain maps.
  defp field(project, key) when is_struct(project), do: Map.get(project, key)

  defp field(project, key) when is_map(project),
    do: Map.get(project, key) || Map.get(project, to_string(key))

  @doc """
  Create a bucket, treating "already yours" as success.

  S3 answers an existing bucket you own with a 409; that is success (marked
  `"adopted"`), so re-running setup converges.

  Blocks until the bucket answers a HEAD: Hetzner lists a new bucket at once
  while writes to it still 404 for about a second.
  """
  @spec ensure_bucket(String.t(), credentials(), keyword()) :: {:ok, map()} | {:error, term()}
  def ensure_bucket(bucket, credentials, opts \\ []) do
    location = Keyword.get(opts, :location, @default_location)

    bucket
    |> ExAws.S3.put_bucket(location)
    |> run(credentials, location)
    |> case do
      {:ok, _} ->
        await_bucket(bucket, credentials, location, opts, "created")

      {:error, {:http_error, status, %{body: body}}} when status == 409 ->
        if body =~ "BucketAlreadyOwnedByYou" or body =~ "BucketAlreadyExists" do
          Logger.info("[Storage] bucket #{bucket} already exists — reusing")
          # Adopted: it was here before setup ran, so teardown must not
          # remove it.
          {:ok, resource(bucket, location, "adopted")}
        else
          {:error, "creating bucket #{bucket} failed (#{status}): #{body}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Every bucket in the account the credentials belong to."
  @spec list_buckets(credentials(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def list_buckets(credentials, opts \\ []) do
    location = Keyword.get(opts, :location, @default_location)

    with {:ok, %{body: %{buckets: buckets}}} <-
           ExAws.S3.list_buckets() |> run(credentials, location) do
      {:ok, Enum.map(buckets, & &1.name)}
    end
  end

  @doc """
  Set the retention window as a bucket lifecycle rule.

  The rule expires objects under the prefix (dumps by default) after `days`.
  """
  @spec put_lifecycle(String.t(), pos_integer(), credentials(), keyword()) ::
          :ok | {:error, term()}
  def put_lifecycle(bucket, days, credentials, opts \\ []) do
    location = Keyword.get(opts, :location, @default_location)
    prefix = Keyword.get(opts, :prefix, dumps_prefix())

    # Hand-built: ExAws's builder emits the rule's children out of order and
    # without the namespace, which Hetzner's Ceph rejects as MalformedXML.
    body = """
    <?xml version="1.0" encoding="UTF-8"?>
    <LifecycleConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Rule>
        <ID>cms-dump-retention</ID>
        <Filter><Prefix>#{prefix}</Prefix></Filter>
        <Status>Enabled</Status>
        <Expiration><Days>#{days}</Days></Expiration>
      </Rule>
    </LifecycleConfiguration>
    """

    operation = %ExAws.Operation.S3{
      bucket: bucket,
      path: "/",
      http_method: :put,
      resource: "lifecycle",
      body: body,
      headers: %{"content-md5" => Base.encode64(:crypto.hash(:md5, body))},
      service: :s3,
      parser: & &1
    }

    put_lifecycle_rule(operation, bucket, credentials, location, opts)
  end

  # A fresh bucket HEADs 200 before it accepts a lifecycle rule (404
  # NoSuchBucket), so this retries like `get_object/6`.
  defp put_lifecycle_rule(operation, bucket, credentials, location, opts, attempts \\ 20) do
    case run(operation, credentials, location) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        if attempts > 1 and no_such_bucket?(reason) do
          Wait.sleep(Keyword.get(opts, :readiness_interval_ms, 500))
          put_lifecycle_rule(operation, bucket, credentials, location, opts, attempts - 1)
        else
          {:error, reason}
        end
    end
  end

  @doc "The retention window a bucket actually enforces, in days."
  @spec get_lifecycle(String.t(), credentials(), keyword()) ::
          {:ok, pos_integer()} | {:error, term()}
  def get_lifecycle(bucket, credentials, opts \\ []) do
    location = Keyword.get(opts, :location, @default_location)

    with {:ok, %{body: body}} <-
           ExAws.S3.get_bucket_lifecycle(bucket) |> run(credentials, location) do
      case Regex.run(~r{<Days>(\d+)</Days>}, to_string(body)) do
        [_, days] -> {:ok, String.to_integer(days)}
        nil -> {:error, :no_lifecycle}
      end
    end
  end

  @doc """
  The dumps in a bucket, newest first.

  Each entry carries the key, size and when it landed — enough to tell
  whether backups are still arriving without downloading any.
  """
  @spec list_dumps(String.t(), credentials(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_dumps(bucket, credentials, opts \\ []) do
    location = Keyword.get(opts, :location, @default_location)
    prefix = Keyword.get(opts, :prefix, dumps_prefix())

    with {:ok, %{body: %{contents: contents}}} <-
           ExAws.S3.list_objects_v2(bucket, prefix: prefix) |> run(credentials, location) do
      dumps =
        contents
        |> Enum.map(&%{key: &1.key, size: to_integer(&1.size), taken_at: &1.last_modified})
        |> Enum.sort_by(& &1.taken_at, :desc)

      {:ok, dumps}
    end
  end

  @doc """
  Upload one object.

  Not `Content.S3Client`, which signs against the global `:ex_aws` config and
  would send the user's data to the wrong store.
  """
  @spec put_object(String.t(), String.t(), iodata(), credentials(), keyword()) ::
          :ok | {:error, term()}
  def put_object(bucket, key, body, credentials, opts \\ []) do
    location = Keyword.get(opts, :location, @default_location)

    case ExAws.S3.put_object(bucket, key, body) |> run(credentials, location) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Download one object."
  @spec get_object(String.t(), String.t(), credentials(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def get_object(bucket, key, credentials, opts \\ []) do
    location = Keyword.get(opts, :location, @default_location)
    get_object(bucket, key, credentials, location, opts, Keyword.get(opts, :attempts, 6))
  end

  defp get_object(bucket, key, credentials, location, opts, attempts) do
    case ExAws.S3.get_object(bucket, key) |> run(credentials, location) do
      {:ok, %{body: body}} ->
        {:ok, body}

      # `NoSuchBucket` right after a write is Ceph catching up (a different
      # gateway answered). Only that is retried; `NoSuchKey` stays immediate.
      {:error, reason} ->
        if attempts > 1 and no_such_bucket?(reason) do
          Wait.sleep(Keyword.get(opts, :interval_ms, 1_000))
          get_object(bucket, key, credentials, location, opts, attempts - 1)
        else
          {:error, reason}
        end
    end
  end

  defp no_such_bucket?({:http_error, 404, %{body: body}}) when is_binary(body),
    do: String.contains?(body, "NoSuchBucket")

  defp no_such_bucket?(_), do: false

  @doc "Remove one object. Used to empty a bucket before deleting it."
  @spec delete_object(String.t(), String.t(), credentials(), keyword()) :: :ok | {:error, term()}
  def delete_object(bucket, key, credentials, opts \\ []) do
    location = Keyword.get(opts, :location, @default_location)

    case ExAws.S3.delete_object(bucket, key) |> run(credentials, location) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Remove many objects in one request.

  Teardown runs in `on_exit`, where slow means killed and leaked. S3 takes up
  to a thousand keys per request.
  """
  @spec delete_objects(String.t(), [String.t()], credentials(), keyword()) ::
          :ok | {:error, term()}
  def delete_objects(_bucket, [], _credentials, _opts), do: :ok

  def delete_objects(bucket, keys, credentials, opts) do
    location = Keyword.get(opts, :location, @default_location)

    keys
    |> Enum.chunk_every(1000)
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      case ExAws.S3.delete_multiple_objects(bucket, chunk) |> run(credentials, location) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Delete a bucket. Only used by teardown in tests; setup never destroys.

  Retries: Ceph answers 409 for around half a minute after the last object is
  removed while listing the bucket empty.
  """
  @spec delete_bucket(String.t(), credentials(), keyword()) :: :ok | {:error, term()}
  def delete_bucket(bucket, credentials, opts \\ []) do
    location = Keyword.get(opts, :location, @default_location)
    attempts = Keyword.get(opts, :attempts, 8)

    delete_bucket(bucket, credentials, location, opts, attempts)
  end

  # Backing off from 500ms (doubling, capped): Ceph usually catches up in well
  # under a second, and a flat interval made clearing many buckets look hung.
  defp delete_bucket(bucket, credentials, location, opts, attempts) do
    interval = Keyword.get(opts, :delete_interval_ms, 500)

    delete_bucket(bucket, credentials, location, opts, attempts, interval)
  end

  defp delete_bucket(bucket, credentials, location, opts, attempts, interval) do
    case empty_then_delete(bucket, credentials, location) do
      {:ok, _} ->
        :ok

      {:error, _} when attempts > 1 ->
        Wait.sleep(interval)

        delete_bucket(
          bucket,
          credentials,
          location,
          opts,
          attempts - 1,
          min(interval * 2, Keyword.get(opts, :max_delete_interval_ms, 8_000))
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  # S3 refuses to delete a bucket that still holds objects or unfinished
  # multipart uploads (a registry bucket holds both).
  defp empty_then_delete(bucket, credentials, location) do
    with :ok <- empty_bucket(bucket, credentials, location),
         :ok <- abort_uploads(bucket, credentials, location) do
      ExAws.S3.delete_bucket(bucket) |> run(credentials, location)
    end
  end

  # Unfinished multipart parts hold a bucket open, `list_objects_v2` does not
  # show them, and Hetzner reports the refusal as a timeout. An interrupted
  # registry push leaves them.
  defp abort_uploads(bucket, credentials, location) do
    case ExAws.S3.list_multipart_uploads(bucket) |> run(credentials, location) do
      {:ok, %{body: %{uploads: uploads}}} -> abort_each(bucket, uploads, credentials, location)
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp abort_each(bucket, uploads, credentials, location) do
    Enum.reduce_while(uploads, :ok, fn upload, :ok ->
      abort = ExAws.S3.abort_multipart_upload(bucket, upload.key, upload.upload_id)

      case run(abort, credentials, location) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # A page at a time, always from the start: a continuation token taken before
  # a delete points into a listing that no longer exists.
  defp empty_bucket(bucket, credentials, location) do
    case ExAws.S3.list_objects_v2(bucket) |> run(credentials, location) do
      {:ok, %{body: %{contents: []}}} ->
        :ok

      {:ok, %{body: %{contents: contents}}} ->
        keys = Enum.map(contents, & &1.key)

        with :ok <- delete_objects(bucket, keys, credentials, location: location) do
          empty_bucket(bucket, credentials, location)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Where dumps live inside a bucket."
  @spec dumps_prefix() :: String.t()
  def dumps_prefix, do: "dumps/"

  @doc """
  A project's storage credentials, or `:none`.

  Read from `ProjectSecrets`, never the platform's own environment: these are
  the user's keys.

  `opts[:environment]` is tried first, for a project that keeps UAT and
  production on separate key pairs; otherwise the shared `"global"` secret.
  Hetzner's access keys are not bucket-scoped, so one pair ordinarily serves
  every environment.
  """
  @spec credentials(Scope.t(), keyword()) :: {:ok, credentials()} | :none
  def credentials(%Scope{} = scope, opts \\ []) do
    location = Keyword.get(opts, :location, @default_location)

    case Keyword.get(opts, :environment) do
      nil -> fetch_credentials(scope, [])
      environment -> fetch_credentials(scope, environment: environment) |> or_global(scope)
    end
    |> with_region(location)
  end

  defp or_global(:none, scope), do: fetch_credentials(scope, [])
  defp or_global(result, _scope), do: result

  defp fetch_credentials(scope, secret_opts) do
    with {:ok, id} when id != "" <-
           ProjectSecrets.fetch_value(scope, "hetzner_s3_access_key_id", secret_opts),
         {:ok, secret} when secret != "" <-
           ProjectSecrets.fetch_value(scope, "hetzner_s3_secret_access_key", secret_opts) do
      {:ok, id, secret}
    else
      _ -> :none
    end
  end

  defp with_region(:none, _location), do: :none

  defp with_region({:ok, id, secret}, location),
    do: {:ok, [access_key_id: id, secret_access_key: secret, region: location]}

  @doc "What the user is told to do when the project has no storage keys yet."
  @spec credentials_instructions() :: String.t()
  def credentials_instructions do
    "Hetzner does not issue object-storage keys over an API — they exist only in the console. " <>
      "Open Hetzner Cloud → your project → Object Storage → Credentials, generate a key pair, " <>
      "and save it on this project as `hetzner_s3_access_key_id` and " <>
      "`hetzner_s3_secret_access_key`. Setup will re-check when you resume. If UAT and " <>
      "production should use separate keys, save each pair with its own environment " <>
      "instead of leaving both on the shared default."
  end

  @doc """
  The same instructions, naming the page to save the keys on.

  For a step that pauses: whoever reads that (often an agent) is not looking
  at the app. An agent must never be handed a credential to relay, so this
  names the page where a person saves the keys; the value goes from the
  browser to the server, and setup re-checks on resume.
  """
  @spec credentials_instructions(term()) :: String.t()
  def credentials_instructions(project_id) do
    credentials_instructions() <> " Save them at #{credentials_url(project_id)}."
  end

  # Built from `:base_url` rather than `~p`: verified routes bind an endpoint
  # at compile time, and this string is read on another machine.
  defp credentials_url(project_id) do
    base = Application.get_env(:code_my_spec, :base_url) || "https://codemyspec.com"

    String.trim_trailing(base, "/") <> "/projects/#{project_id}/provisioning/credentials"
  end

  ## Internals

  defp resource(bucket, location, origin) do
    %{
      name: bucket,
      location: "#{location}.your-objectstorage.com/#{bucket}",
      owner: "user",
      origin: origin
    }
  end

  # Bounded: a bucket that never answers is a provider problem to report, not
  # to hang on.
  defp await_bucket(bucket, credentials, location, opts, origin, attempts \\ 20) do
    case ExAws.S3.head_bucket(bucket) |> run(credentials, location) do
      {:ok, _} ->
        {:ok, resource(bucket, location, origin)}

      {:error, _} when attempts > 1 ->
        Wait.sleep(Keyword.get(opts, :readiness_interval_ms, 500))
        await_bucket(bucket, credentials, location, opts, origin, attempts - 1)

      {:error, reason} ->
        {:error, "bucket #{bucket} was created but never became usable: #{inspect(reason)}"}
    end
  end

  # Path-style throughout: a host that already carries the bucket would
  # produce `bucket.host/bucket/` and NoSuchBucket.
  defp run(operation, credentials, location) do
    config =
      Keyword.merge(
        [
          http_client: CodeMySpec.Content.ExAwsReqClient,
          host: "#{location}.your-objectstorage.com",
          region: location,
          scheme: "https://",
          port: 443
        ],
        credentials
      )

    ExAws.request(operation, config)
  end

  defp to_integer(nil), do: 0
  defp to_integer(value), do: String.to_integer(value)
end
