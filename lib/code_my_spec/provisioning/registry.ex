defmodule CodeMySpec.Provisioning.Registry do
  @moduledoc """
  Where built images live, and how they stop costing money.

  One registry, ours, backed by one bucket, with a repository per project.

  It was briefly designed the other way — a registry per customer, backed by
  each customer's own bucket. That is what "self-hosted" suggested, and it is
  the opposite of what the story asks for. Story 992 is called *my images are
  built on infrastructure I never maintain*: a bucket Sam pays for, holding a
  registry Sam's lifecycle rule prunes, is infrastructure Sam maintains. It
  also meant one registry process per customer, since a registry takes exactly
  one storage backend.

  Neither criterion asked for it. 8240 wants a deploy that pulls without a
  GitHub credential; 8241 wants old images to expire without anyone
  remembering. One shared registry does both, and needs no extra server —
  it belongs to the CodeMySpec deployment, beside everything else we run.

  Retention is still the bucket lifecycle rule we have already written and
  debugged against Hetzner's Ceph, which is the part of running a registry that
  actually bites: they fill disks silently, because every image ever built
  stays until something deletes it.

  This owns the bucket, the retention and the address. Serving the registry
  protocol is `distribution`'s job, not ours.
  """

  alias CodeMySpec.Provisioning.Storage
  alias CodeMySpec.Users.Scope

  # Long enough to roll back to something that worked, short enough that a
  # weekly deploy cadence does not accumulate a year of images. Overridable,
  # because a project that deploys hourly wants a different answer.
  @default_retention_days 30

  # A registry keeps blobs and manifests apart. Retention applies to blobs:
  # they are what the space goes on, and a manifest pointing at expired blobs
  # is already unusable.
  @blobs_prefix "docker/registry/v2/blobs/"

  @doc """
  Make sure the registry's bucket exists and forgets old images on its own.

  Idempotent: setup runs more than once, and a registry that already exists is
  the ordinary case rather than a problem.
  """
  @spec ensure(Scope.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def ensure(%Scope{} = scope, opts \\ []) do
    with {:ok, credentials} <- credentials(scope, opts),
         bucket <- bucket_name(scope, opts),
         {:ok, _} <- Storage.ensure_bucket(bucket, credentials, opts),
         :ok <- put_retention(bucket, credentials, opts) do
      {:ok, bucket}
    end
  end

  @doc """
  The address a deploy pulls an image from.

  Built rather than reported back by the builder: the deploy has to know where
  to look before anything has been pushed, and a reference the builder invents
  is one more thing that can disagree with where it actually went.
  """
  @spec reference(Scope.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def reference(%Scope{} = scope, tag, opts \\ []) when is_binary(tag) do
    with {:ok, host} <- host(opts),
         {:ok, repository} <- repository(scope, opts) do
      {:ok, "#{host}/#{repository}:#{tag}"}
    end
  end

  @doc "How long images are kept, in days."
  @spec retention_days(keyword()) :: pos_integer()
  def retention_days(opts), do: Keyword.get(opts, :retention_days, @default_retention_days)

  @doc "The prefix retention applies to."
  @spec blobs_prefix() :: String.t()
  def blobs_prefix, do: @blobs_prefix

  defp put_retention(bucket, credentials, opts) do
    Storage.put_lifecycle(
      bucket,
      retention_days(opts),
      credentials,
      Keyword.put(opts, :prefix, @blobs_prefix)
    )
  end

  defp credentials(scope, opts) do
    case Keyword.get(opts, :credentials) || Storage.credentials(scope, opts) do
      :none -> {:error, :no_storage_credentials}
      {:ok, credentials} -> {:ok, credentials}
      credentials when is_list(credentials) -> {:ok, credentials}
    end
  end

  # One bucket for every project, because the registry is ours. It still gets
  # its own bucket rather than a prefix inside somebody's: a registry's layout
  # is the registry's, and sharing would put its retention rule and the
  # backups' retention rule in one place, where the second one written wins and
  # the first silently stops applying.
  defp bucket_name(_scope, opts) do
    Keyword.get(opts, :bucket) || configured_bucket() || "codemyspec-registry"
  end

  defp configured_bucket,
    do: Application.get_env(:code_my_spec, __MODULE__, [])[:bucket]

  defp repository(scope, opts) do
    case Keyword.get(opts, :repository) || project_slug(scope) do
      slug when is_binary(slug) and slug != "" -> {:ok, slug}
      _ -> {:error, :no_project}
    end
  end

  # `:registry_host`, not `:host`. The deploy step hands its whole opts list to
  # `reference/3`, and `:host` there is already the app's own hostname — so
  # reading it would have addressed every image at the customer's domain
  # instead of the registry, and the deploy would have tried to pull from
  # itself.
  defp host(opts) do
    case Keyword.get(opts, :registry_host) || configured_host() do
      host when is_binary(host) and host != "" -> {:ok, host}
      _ -> {:error, :no_registry_host}
    end
  end

  defp configured_host,
    do: Application.get_env(:code_my_spec, __MODULE__, [])[:host]

  defp project_slug(%Scope{active_project: %{name: name}}) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp project_slug(_scope), do: nil
end
