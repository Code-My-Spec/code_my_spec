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

  alias CodeMySpec.Provisioning.Wait

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

    put_lifecycle_rule(operation, bucket, credentials, location, opts)
  end

  # A fresh bucket HEADs 200 before it will accept a lifecycle rule, so
  # `await_bucket/6` returning is not a promise this call will land — same Ceph
  # lag `get_object/6` already retries, caught by the drill as a 404
  # NoSuchBucket one interaction after the bucket HEADed 200.
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
    get_object(bucket, key, credentials, location, opts, Keyword.get(opts, :attempts, 6))
  end

  defp get_object(bucket, key, credentials, location, opts, attempts) do
    case ExAws.S3.get_object(bucket, key) |> run(credentials, location) do
      {:ok, %{body: body}} ->
        {:ok, body}

      # `NoSuchBucket` on a bucket we have just written to is Hetzner's Ceph
      # catching up, not a missing bucket: the gateway that answers the read
      # need not be the one that took the write. Retried narrowly — only this
      # code, never `NoSuchKey` — because a genuinely absent object must stay
      # an immediate answer rather than an eight-second wait.
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

  One round trip per object made emptying a bucket the slow half of teardown,
  and teardown runs in `on_exit` where slow means "killed by a timeout, and the
  bucket leaks". S3 takes up to a thousand keys at a time.
  """
  @spec delete_objects(String.t(), [String.t()], credentials(), keyword()) :: :ok | {:error, term()}
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

  # Backing off rather than sleeping a flat ten seconds each time. Ceph usually
  # catches up in well under a second, so a fixed interval spent the entire
  # budget waiting on the common case: eight attempts at ten seconds is eighty
  # seconds per bucket, and clearing a dozen of them read as a hang rather than
  # as a retry. Doubling from half a second covers the same worst case in a
  # quarter of the time and returns almost immediately when the bucket was
  # ready all along.
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

  # S3 will not delete a bucket that still holds objects, so this emptied
  # nothing and retried the refusal eight times.
  #
  # It went unnoticed for as long as every bucket teardown removed was empty.
  # The registry's is not — it holds the image layers, which is the whole
  # point of it — so a project's registry bucket could never be deleted, and
  # the next drill refused to start on residue its own teardown was incapable
  # of clearing.
  #
  # A page at a time, because a bucket with thousands of layers is exactly the
  # case that breaks a single listing.
  defp empty_then_delete(bucket, credentials, location) do
    with :ok <- empty_bucket(bucket, credentials, location),
         :ok <- abort_uploads(bucket, credentials, location) do
      ExAws.S3.delete_bucket(bucket) |> run(credentials, location)
    end
  end

  # Parts of uploads that were started and never finished.
  #
  # They hold a bucket open exactly like objects do, and `list_objects_v2`
  # does not show them — so a registry bucket that had had a push interrupted
  # listed as empty and still refused to delete, which Hetzner reports as a
  # request that times out rather than as `BucketNotEmpty`. A registry push is
  # multipart by nature and a drill is killed mid-push often enough, so this
  # is the normal state of the bucket rather than an edge case.
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

  # A page at a time, always from the start, until the bucket lists empty.
  #
  # From the start rather than following a continuation token, because the
  # objects in the page just deleted are gone — a token taken before a delete
  # points into a listing that no longer exists. Re-listing costs one request
  # per page and cannot skip anything.
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

  Read from `ProjectSecrets` rather than the platform's own environment: these
  are Sam's keys, held for him, and the whole story falls apart if setup
  quietly falls back to ours.

  `opts[:environment]`, when given, is tried first — a project that wants
  UAT and production isolated at the credential level, not just the bucket
  level (a distinct Hetzner project/console key per environment, matching
  how `database_password_<environment>` and `age_private_key_<environment>`
  already keep those two apart), can set one. Falls back to the shared
  `"global"` secret otherwise, which is what every project has by default:
  Hetzner's own access keys are not bucket-scoped, so one key pair
  ordinarily manages every environment's bucket fine.
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

  @doc "What Sam is told to go do when his project has no storage keys yet."
  @spec credentials_instructions() :: String.t()
  def credentials_instructions do
    "Hetzner does not issue object-storage keys over an API — they exist only in the console. " <>
      "Open Hetzner Cloud → your project → Object Storage → Credentials, generate a key pair, " <>
      "and save it on this project as `hetzner_s3_access_key_id` and " <>
      "`hetzner_s3_secret_access_key`. Setup will re-check when you resume. If UAT and " <>
      "production should use separate keys, save each pair with its own environment " <>
      "instead of leaving both on the shared default."
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
        Wait.sleep(Keyword.get(opts, :readiness_interval_ms, 500))
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
