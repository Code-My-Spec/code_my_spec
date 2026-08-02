defmodule CodeMySpec.Provisioning.Storage do
  @moduledoc """
  Object storage in Sam's own Hetzner account — buckets, retention, and the
  dumps that land in them.

  ## The buckets are his, and that is the point

  Story 968 exists because uploads and database dumps held in platform-owned
  storage stop being Sam's the day he stops paying us. Every call here signs
  with *his* credentials against *his* account, so the resources this creates
  survive us. `owner: "user"` on each recorded resource is that claim made
  checkable (criterion 8011), not a label.

  ## One bucket per environment

  `bucket_name/2` derives a distinct bucket per environment because criterion
  8012 is about a specific failure: poking at UAT puts a test upload in the
  same place as real customer data, with nothing afterwards to tell the two
  apart. Separate buckets make that mistake impossible rather than merely
  discouraged.

  ## Retention is the bucket's job

  `put_lifecycle/4` sets an S3 lifecycle rule rather than scheduling a delete
  job. Criterion 8016 asks for retention *enforced* rather than hoped for, and
  a pruning script is one broken cron away from a bill that grows forever —
  quietly, for exactly as long as nobody looks. A lifecycle rule keeps running
  when the server it was configured from is gone.

  ## Credentials

  Hetzner will not mint S3 keys over an API — they are created in the console
  and nowhere else. So this module never tries: it takes the credentials it is
  given, and the `storage` step pauses to ask for them when a project has
  none. That pause is honest about a real provider limit, and re-verifies on
  return rather than trusting that the errand was done (criterion 7967).
  """

  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Users.Scope

  require Logger

  # Hetzner's object storage speaks S3 per location, and the location is both
  # the host and the signing region.
  @default_location "fsn1"

  @type credentials :: [access_key_id: String.t(), secret_access_key: String.t(), region: String.t()]

  @doc """
  The bucket for one environment of one project.

  Bucket names are globally unique within a provider and DNS-shaped, so this
  lowercases and strips anything S3 will not take rather than trusting a
  project name to already be legal — project names are free text and bucket
  names are not.

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
          # Deliberately not a generic fallback. Bucket names are unique per
          # account, so "project-prod" would be *shared* by every project
          # missing a name — two of Sam's apps writing dumps and uploads into
          # one bucket, discovered when one of them restores the other's data.
          raise ArgumentError,
                "cannot derive a bucket name: #{inspect(project)} has no name"
      end

    "#{base}-#{environment}"
  end

  # Projects arrive as an Ecto struct here and as a plain map in tests and
  # fixtures; structs do not implement Access, so `project[:name]` raises on
  # the real one. This reads both without the caller having to care.
  defp field(project, key) when is_struct(project), do: Map.get(project, key)

  defp field(project, key) when is_map(project),
    do: Map.get(project, key) || Map.get(project, to_string(key))

  @doc """
  Create a bucket, treating "already yours" as success.

  Re-running setup must converge (criterion 7965), and S3 answers an existing
  bucket you own with a 409 rather than a 200. Reporting that as failure would
  make the second run of an idempotent step fail, which is the opposite of
  what convergence means.

  ## It waits for the bucket to be usable, not merely created

  Hetzner answers `PUT /bucket` immediately and lists the bucket right after,
  while object writes to it still 404 for about a second. Returning as soon as
  the create succeeds therefore hands the caller a bucket that rejects the
  first upload — and the backups step uploads a dump the moment storage is
  done, so the failure lands on the first run and disappears on the second.
  That is the worst shape a bug can have, so this blocks until the bucket
  actually answers.
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

  The rule expires objects under the dumps prefix after `days`. Criterion 8016
  wants retention the bucket enforces on its own — see the moduledoc for why a
  pruning job is not the same promise.
  """
  @spec put_lifecycle(String.t(), pos_integer(), credentials(), keyword()) ::
          :ok | {:error, term()}
  def put_lifecycle(bucket, days, credentials, opts \\ []) do
    location = Keyword.get(opts, :location, @default_location)
    prefix = Keyword.get(opts, :prefix, dumps_prefix())

    # Hand-built rather than `ExAws.S3.put_bucket_lifecycle/2`: that builder
    # emits the rule's children in reverse (Filter, Status, ID) and omits the
    # namespace. Amazon accepts it; Hetzner runs Ceph, which answers
    # MalformedXML. So the XML is written in the documented order here.
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

    case run(operation, credentials, location) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
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

  Each entry carries the key, its size and when it landed — enough for the
  page to say whether backups are still arriving without downloading any of
  them.
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

  Deliberately not `Content.S3Client`, which signs against whatever the global
  `:ex_aws` config points at — for the content-publishing path that is the
  right answer, and here it would send Sam's dumps to Amazon instead of the
  Hetzner bucket this module just created.
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

    with {:ok, %{body: body}} <- ExAws.S3.get_object(bucket, key) |> run(credentials, location) do
      {:ok, body}
    end
  end

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
  Delete a bucket. Only used by teardown in tests; setup never destroys.

  Retries, because Ceph answers 409 for around half a minute after the last
  object is removed — the listing reports the bucket empty the whole time. A
  teardown that gave up on the first 409 left buckets behind, and a bucket
  left behind is a line on somebody's invoice.
  """
  @spec delete_bucket(String.t(), credentials(), keyword()) :: :ok | {:error, term()}
  def delete_bucket(bucket, credentials, opts \\ []) do
    location = Keyword.get(opts, :location, @default_location)
    attempts = Keyword.get(opts, :attempts, 8)

    delete_bucket(bucket, credentials, location, opts, attempts)
  end

  defp delete_bucket(bucket, credentials, location, opts, attempts) do
    case ExAws.S3.delete_bucket(bucket) |> run(credentials, location) do
      {:ok, _} ->
        :ok

      {:error, _} when attempts > 1 ->
        Process.sleep(Keyword.get(opts, :delete_interval_ms, 10_000))
        delete_bucket(bucket, credentials, location, opts, attempts - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Where dumps live inside a bucket."
  @spec dumps_prefix() :: String.t()
  def dumps_prefix, do: "dumps/"

  @doc """
  A project's storage credentials, or `:none`.

  Read from `ProjectSecrets` rather than the platform's own environment: these
  are Sam's keys, held for him, and the whole story falls apart if setup
  quietly falls back to ours.
  """
  @spec credentials(Scope.t(), keyword()) :: {:ok, credentials()} | :none
  def credentials(%Scope{} = scope, opts \\ []) do
    location = Keyword.get(opts, :location, @default_location)

    with {:ok, id} when id != "" <- ProjectSecrets.fetch_value(scope, "hetzner_s3_access_key_id"),
         {:ok, secret} when secret != "" <-
           ProjectSecrets.fetch_value(scope, "hetzner_s3_secret_access_key") do
      {:ok, [access_key_id: id, secret_access_key: secret, region: location]}
    else
      _ -> :none
    end
  end

  @doc "What Sam is told to go do when his project has no storage keys yet."
  @spec credentials_instructions() :: String.t()
  def credentials_instructions do
    "Hetzner does not issue object-storage keys over an API — they exist only in the console. " <>
      "Open Hetzner Cloud → your project → Object Storage → Credentials, generate a key pair, " <>
      "and save it on this project as `hetzner_s3_access_key_id` and " <>
      "`hetzner_s3_secret_access_key`. Setup will re-check when you resume."
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

  # ExAws.S3 owns the operations and the signing; this only supplies the
  # endpoint. Path-style throughout: ExAws prepends the bucket to the path
  # unless `virtual_host: true`, so a host that already carries the bucket
  # produces `bucket.host/bucket/` and a NoSuchBucket on a call that was
  # meant to create it. Found live.
  # Bounded, and deliberately not infinite: a bucket that never answers is a
  # provider problem the step should report rather than hang on.
  defp await_bucket(bucket, credentials, location, opts, origin, attempts \\ 20) do
    case ExAws.S3.head_bucket(bucket) |> run(credentials, location) do
      {:ok, _} ->
        {:ok, resource(bucket, location, origin)}

      {:error, _} when attempts > 1 ->
        Process.sleep(Keyword.get(opts, :readiness_interval_ms, 500))
        await_bucket(bucket, credentials, location, opts, origin, attempts - 1)

      {:error, reason} ->
        {:error,
         "bucket #{bucket} was created but never became usable: #{inspect(reason)}"}
    end
  end

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
