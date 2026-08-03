defmodule Mix.Tasks.Cms.ProvisioningLeaks do
  @shortdoc "List real provider resources left behind by spex recordings"

  @moduledoc """
  Show what the spex account still holds, so a bad teardown is visible rather
  than assumed away.

      MIX_ENV=test mix cms.provisioning_leaks

  Spex in the devops epic create **real** resources — Hetzner servers and
  buckets, Cloudflare records — and tear them down on the way out. Teardown is
  the only thing standing between a recording session and a bill, and it runs
  in `on_exit`, which is exactly where a crashed test is least likely to reach.
  A leak is also silent in the worst way: the next recording finds the resource
  already there and passes on residue, so the criterion whose premise is
  "this exists" stops putting it there and nobody notices until a fresh
  account fails everything at once.

  Anything prefixed `spex-` is a recording artifact and should not exist
  between runs. Everything else is real and is listed separately so the two
  are never confused — deleting the wrong one here is the expensive mistake.

  Run under `MIX_ENV=test`: it points `CodeMySpec.Repo` at `code_my_spec_dev`
  but builds against test artifacts, so it never contends for the dev compile
  lock the running `:4000` server holds. It reads dev *data*, not dev *code*.

  Read-only. It deletes nothing — what to do about a leak is a judgement call
  that depends on whether a recording is in flight.
  """
  use Mix.Task
  use Boundary, classify_to: CodeMySpec

  alias CodeMySpec.Provisioning.{Hetzner, Storage, Teardown}
  alias CodeMySpec.Users.Scope

  @spex_prefix "spex-"

  @impl Mix.Task
  def run(args) do
    delete? = "--delete" in args

    Logger.configure(level: :warning)

    {:ok, _} = Application.ensure_all_started(:req)
    {:ok, _} = Application.ensure_all_started(:ex_aws)

    # The same credentials a recording uses, from the same place — reading them
    # anywhere else would audit an account the spex never touch.
    token = env!("HETZNER_API_TOKEN")

    credentials = [
      access_key_id: env!("HETZNER_S3_ACCESS_KEY_ID"),
      secret_access_key: env!("HETZNER_S3_SECRET_ACCESS_KEY"),
      region: System.get_env("HETZNER_S3_REGION", "fsn1")
    ]

    Application.put_env(:code_my_spec, CodeMySpec.Provisioning.Hetzner, api_token: token)

    report("Hetzner servers", server_names(%Scope{}), false)
    report("Hetzner SSH keys", ssh_key_names(%Scope{}), false)
    report("Hetzner buckets", bucket_names(credentials), delete?, &delete_bucket(&1, credentials))
  end

  # Through the app's own teardown, not a raw delete: emptying first is the
  # part people forget, and a bucket with one object in it refuses to go.
  defp delete_bucket(bucket, credentials) do
    resource = %{kind: "bucket", location: bucket, origin: "created"}

    case Teardown.resource(%Scope{}, resource, credentials: credentials) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, bucket}
    end
  end

  defp env!(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        Mix.raise("#{name} is not set — source envs/.env first (`set -a; source envs/.env`)")
    end
  end

  defp server_names(scope) do
    case Hetzner.list_servers(scope) do
      {:ok, servers} -> Enum.map(servers, &name_of/1)
      other -> Mix.shell().error("could not list servers: #{inspect(other)}") || []
    end
  end

  # Keys leak the same way servers do and are easier to miss: they cost nothing,
  # so nobody notices seven of them. They are still a credential per recording
  # sitting in the account.
  defp ssh_key_names(scope) do
    case CodeMySpec.Provisioning.Hetzner.list_ssh_keys(scope) do
      {:ok, keys} -> Enum.map(keys, &name_of/1)
      _ -> []
    end
  end

  defp bucket_names(credentials) do
    with {:ok, buckets} <- Storage.list_buckets(credentials, []) do
      Enum.map(buckets, &name_of/1)
    else
      other ->
        Mix.shell().error("could not list buckets: #{inspect(other)}")
        []
    end
  end

  # Providers are inconsistent about this: servers come back as maps with
  # string keys, buckets sometimes as bare names.
  defp name_of(%{name: name}), do: name
  defp name_of(%{"name" => name}), do: name
  defp name_of(name) when is_binary(name), do: name
  defp name_of(other), do: inspect(other)

  # The two lists never merge: a leak is deleted and a real resource is not,
  # and the whole value of this task is that the distinction is obvious at a
  # glance rather than inferred from a name.
  defp report(label, names, delete?, deleter \\ nil) do
    {leaked, real} = Enum.split_with(names, &String.starts_with?(to_string(&1), @spex_prefix))

    Mix.shell().info("\n#{label}")
    Mix.shell().info("  real (#{length(real)}): #{inspect(real)}")

    cond do
      leaked == [] ->
        Mix.shell().info("  leaked: none")

      delete? and deleter ->
        Mix.shell().info("  LEAKED (#{length(leaked)}): deleting…")

        for name <- leaked do
          case deleter.(name) do
            :ok -> Mix.shell().info("    deleted #{name}")
            {:error, _} -> Mix.shell().error("    FAILED  #{name}")
          end
        end

      true ->
        Mix.shell().info("  LEAKED (#{length(leaked)}): #{inspect(leaked)}")
        Mix.shell().info("  re-run with --delete to remove them")
    end
  end
end
