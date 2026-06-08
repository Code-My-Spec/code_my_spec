# Secrets: Varlock (local) → AWS SSM Parameter Store (prod)

How secrets flow for a Phoenix/Elixir app deployed with Kamal. Two backends, one source of truth per stage:

- **Local/dev & seeding:** [Varlock](https://varlock.dev) — a committed `.env.schema` with device-encrypted ciphertext. No `.env` files, no plaintext on disk, AI-safe (agents only ever see ciphertext).
- **Prod/UAT runtime:** AWS **SSM Parameter Store** (SecureString) — fetched at container boot by `MyApp.Secrets.load!/1`. Kamal carries only the AWS bootstrap creds needed to make that call.

This supersedes the old "`/opt/<proj>/{prod,uat}.env` mode-600 host file + Dotenvy" pattern.

Companion playbooks: `hetzner-docker-deploy.md` (consumes these), `aws-s3-iam.md` (the IAM user + KMS-via-SSM permission).

---

## 1. Local secrets — Varlock

`.env.schema` is **committed** (`.gitignore` has `!.env.schema`) and is the single source of truth for env config. Secret values are encrypted to the machine's secure enclave; only that machine (Touch ID / device key) can decrypt them.

```bash
# .env.schema
# @defaultRequired=true
# @defaultSensitive=false
# ---

# @type=url
CODEMYSPEC_URL=https://codemyspec.com            # plaintext, non-secret

# @sensitive=true
RESEND_API_KEY=varlock("local:AQTm/8fJ…")        # enclave-encrypted ciphertext

# @sensitive=true
AWS_ACCESS_KEY_ID=varlock("local:AQR+Ts7J…")     # the app IAM user (S3 + SSM)
# @sensitive=true
AWS_SECRET_ACCESS_KEY=varlock("local:AQSdVci…")

AWS_REGION=us-east-1
S3_BUCKET=myapp-prod-files
```

Decorators (`@type`, `@required`, `@sensitive`, `@defaultRequired`) give schema validation at run time. Run the app with Varlock injecting the resolved env into the process:

```bash
varlock run -- mix phx.server
varlock run -- mix test
varlock run -- bash scripts/build-ssm-env prod    # used for seeding SSM, below
```

Encrypt a new secret into the schema (writes the `varlock("local:…")` ciphertext):

```bash
varlock set RESEND_API_KEY        # prompts for the value, encrypts, edits .env.schema
```

> **Device-binding caveat:** `local:` ciphertext only decrypts on the machine that encrypted it. For a multi-dev team, move secrets to a shared backend resolver (`op(…)` for 1Password, or AWS Secrets Manager) instead of `local:`. The schema/validation stays the same.

Prod does **not** use Varlock — `config/runtime.exs` only reads `System.get_env/1`, which is populated from SSM (next section). A `varlock run` wrapper is unnecessary in the container.

---

## 2. Prod/UAT secrets — SSM Parameter Store

### Path convention

```
/<app>/<env>/<UPPER_SNAKE_KEY>      e.g.  /myapp/prod/DATABASE_URL
                                          /myapp/prod/SECRET_KEY_BASE
                                          /myapp/uat/CLOAK_KEY
```

All stored as **SecureString** (KMS-encrypted). One IAM user per app reads its own subtree (see `aws-s3-iam.md`).

### Boot-time loader

`MyApp.Secrets.load!/1` runs at the **top of `config/runtime.exs`**, before any `System.get_env/1` call, and writes every SSM param into the OS env:

```elixir
# lib/myapp/secrets.ex
defmodule MyApp.Secrets do
  @path_prefix "/myapp/"
  @max_attempts 3
  @backoff_ms 1000

  @spec load!(String.t()) :: :ok
  def load!(app_env) when app_env in ["prod", "uat"] do
    {:ok, _} = Application.ensure_all_started(:ex_aws)
    {:ok, _} = Application.ensure_all_started(:hackney)

    path = @path_prefix <> app_env <> "/"
    params = fetch_all(path, nil, [])
    params == [] && raise "No SSM parameters found under #{path}."

    Enum.each(params, fn %{"Name" => name, "Value" => value} ->
      System.put_env(String.replace_prefix(name, path, ""), value)
    end)
    :ok
  end

  defp fetch_all(path, token, acc) do
    case fetch_page(path, token) do
      {:ok, %{"Parameters" => p, "NextToken" => t}} when is_binary(t) -> fetch_all(path, t, [p | acc])
      {:ok, %{"Parameters" => p}} -> Enum.reverse([p | acc]) |> List.flatten()
    end
  end

  defp fetch_page(path, token, attempt \\ 1) do
    opts = [recursive: true, with_decryption: true]
    opts = if token, do: Keyword.put(opts, :next_token, token), else: opts

    case ExAws.SSM.get_parameters_by_path(path, opts) |> ExAws.request() do
      {:ok, page} -> {:ok, page}
      {:error, _} when attempt < @max_attempts ->
        Process.sleep(@backoff_ms); fetch_page(path, token, attempt + 1)
      {:error, reason} -> raise "SSM fetch failed for #{path}: #{inspect(reason)}"
    end
  end
end
```

```elixir
# config/runtime.exs — FIRST thing, before any System.get_env/1 below it
if config_env() == :prod do
  MyApp.Secrets.load!(System.get_env("APP_ENV") || "prod")
  config :ex_aws, region: System.get_env("AWS_REGION") || "us-east-1"
end
```

Critical details:
- **Pagination + retry.** `get_parameters_by_path` pages via `NextToken`; the loader follows all pages and retries transient failures (3×, 1 s backoff) before raising.
- **`extra_applications` ordering.** ExAws + HTTP client must be available before `runtime.exs` runs. Declare them in `mix.exs` so the release includes them:
  ```elixir
  extra_applications: [:logger, :runtime_tools, :ex_aws_ssm, :hackney, :castore]
  ```
- **`APP_ENV`, not `MIX_ENV`.** One `MIX_ENV=prod` image serves prod and uat; Kamal sets `APP_ENV` per environment (`env.clear.APP_ENV`), and that picks the SSM subtree. No separate uat image.
- **Fail loud.** An empty result set raises — a misconfigured IAM user or wrong path crashes the boot instead of silently running with no secrets.

### What Kamal carries

`.kamal/secrets-common` holds **only** what's needed to reach SSM + GHCR — never app secrets:

```bash
KAMAL_REGISTRY_PASSWORD=${KAMAL_REGISTRY_PASSWORD}   # = gh auth token
AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}               # the app IAM user's long-term key
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
```

`scripts/deploy` populates these in the shell (from SSM via the shared `devops/scripts/render-env`, and `gh auth token`) before invoking Kamal. See the silent-creds-fail guard in `hetzner-docker-deploy.md` §5.

---

## 3. Seeding SSM

Each app ships `scripts/build-ssm-env`: it renders a full `KEY=VALUE` env file for an environment from the Varlock-resolved context, generating cryptographic keys fresh, then hands off to the shared `devops/scripts/seed-secrets` to upload every key as a SecureString param.

```bash
# Run under varlock so the app IAM creds + integration keys are decrypted.
# DATABASE_URL is provided externally (from the shared DB-provisioning step).
DATABASE_URL='ecto://myapp_prod_app:…@infra-postgres-1/myapp_prod' \
  varlock run -- bash scripts/build-ssm-env prod > /tmp/myapp-prod.env

~/Documents/github/devops/scripts/seed-secrets myapp prod /tmp/myapp-prod.env
rm /tmp/myapp-prod.env
```

`build-ssm-env` generates fresh values per run for keys that should be unique per environment:

```bash
SECRET_KEY_BASE=$(openssl rand -base64 64)
CLOAK_KEY=$(openssl rand -base64 32)       # 32 bytes for AES-256-GCM at-rest (Cloak)
```

> **Re-run warning:** regenerating `SECRET_KEY_BASE` invalidates existing sessions; regenerating `CLOAK_KEY` makes all Cloak-encrypted DB columns undecryptable. Only seed these once per env, or carry the existing values forward.

---

## 4. Rotation

- **App secret (e.g. `RESEND_API_KEY`):** `varlock set` the new value locally, re-run `build-ssm-env` + `seed-secrets` (or `aws ssm put-parameter --overwrite`), then redeploy / restart so `Secrets.load!/1` re-reads it. A no-code-change "roll secrets" is just `kamal deploy --skip-push --version=<current-sha>` after updating SSM.
- **AWS IAM key (bootstrap pair):** mint a new key (`aws iam create-access-key`), `varlock set` both halves, deploy, then delete the old key. See `aws-s3-iam.md`.

---

## 5. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Boot raises "No SSM parameters found under /myapp/<env>/" | Wrong `APP_ENV`, empty AWS creds, or IAM user lacks `ssm:GetParametersByPath` on the path. |
| `(ArgumentError) ... AccessDenied` on SecureString | IAM user missing `kms:Decrypt` via SSM — add the `kms:ViaService: ssm.<region>` statement (`aws-s3-iam.md`). |
| Secrets work locally, missing in prod | A `config/runtime.exs` line reads `System.get_env/1` **above** the `Secrets.load!/1` call. Move the load to the top. |
| `varlock("local:…")` won't decrypt on another machine | Device-binding — re-encrypt on that machine or switch to a shared backend resolver. |
| Deploy ran with empty AWS keys | `render-env` failed silently — use the temp-file + hard-fail guard, never `source <(render-env …)`. |

## References
- Varlock — https://varlock.dev
- AWS SSM `get-parameters-by-path` — https://docs.aws.amazon.com/systems-manager/latest/APIReference/API_GetParametersByPath.html
- ExAws.SSM — https://hexdocs.pm/ex_aws_ssm
