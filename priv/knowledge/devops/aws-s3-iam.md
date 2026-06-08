# AWS S3 and IAM Setup for Phoenix/Elixir

Reference for creating S3 buckets, scoped IAM users, and wiring up ExAws in an Elixir application. Covers multi-environment setup, CLI commands, and JSON policy documents.

## Prerequisites

```bash
brew install awscli
aws configure
aws sts get-caller-identity
```

---

## 1. S3 Bucket Creation

### Naming conventions

Use environment suffixes. Bucket names are globally unique.

| Environment | Bucket name |
|-------------|-------------|
| prod | `myproject-uploads` |
| uat | `myproject-uploads-uat` |
| dev | local disk (no bucket) |

### Create and lock down

```bash
aws s3api create-bucket --bucket myproject-uploads --region us-east-1

aws s3api put-public-access-block \
  --bucket myproject-uploads \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```

Note: `us-east-1` does not accept `--create-bucket-configuration`. For other regions add `--create-bucket-configuration LocationConstraint=eu-central-1`.

### Optional: lifecycle policy

Save as `lifecycle.json`:
```json
{
  "Rules": [
    {
      "ID": "expire-old-files",
      "Status": "Enabled",
      "Filter": { "Prefix": "files/" },
      "Expiration": { "Days": 90 }
    }
  ]
}
```

```bash
aws s3api put-bucket-lifecycle-configuration \
  --bucket myproject-uploads --lifecycle-configuration file://lifecycle.json
```

### CORS (only for direct browser-to-S3 uploads)

Only needed if you use presigned PUT URLs from the frontend. If uploads go through Phoenix, skip this.

```json
[
  {
    "AllowedHeaders": ["*"],
    "AllowedMethods": ["GET", "PUT", "POST", "HEAD"],
    "AllowedOrigins": ["https://myapp.com", "https://uat.myapp.com"],
    "ExposeHeaders": ["ETag"],
    "MaxAgeSeconds": 3000
  }
]
```

---

## 2. IAM User Creation

One IAM user per environment with least-privilege S3 access.

### Create users

```bash
aws iam create-user --user-name myproject-app-prod
aws iam create-user --user-name myproject-app-uat
```

### S3 policy document

Save as `s3-policy-prod.json`:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListBucket",
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::myproject-uploads"
    },
    {
      "Sid": "ObjectOperations",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::myproject-uploads/*"
    }
  ]
}
```

### Create and attach policies

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws iam create-policy \
  --policy-name myproject-s3-prod \
  --policy-document file://s3-policy-prod.json

aws iam attach-user-policy \
  --user-name myproject-app-prod \
  --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/myproject-s3-prod
```

### Generate access keys

```bash
aws iam create-access-key --user-name myproject-app-prod
```

Store `AccessKeyId` and `SecretAccessKey` in the server env file. Never in the repo.

### Rotate keys

```bash
# Create new key first
aws iam create-access-key --user-name myproject-app-prod
# Update server env, then delete old key
aws iam delete-access-key --user-name myproject-app-prod --access-key-id AKIAOLD...
```

---

## 2b. Combined S3 + SSM IAM user (Kamal deploys)

For apps deployed with Kamal (see `hetzner-docker-deploy.md`), the running container needs **both** S3 (file storage) **and** SSM Parameter Store (boot-time secrets — see `secrets-ssm.md`). Use **one IAM user per app+env** with a single policy covering both, plus `kms:Decrypt` scoped to SSM (SecureString params are KMS-encrypted).

### Policy template

Commit a templated policy (`deploy/aws/<app>-app-policy.json`) with `{{PLACEHOLDER}}` tokens so account IDs aren't hardcoded:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "SsmReadAppParams", "Effect": "Allow",
      "Action": ["ssm:GetParametersByPath", "ssm:GetParameters", "ssm:GetParameter"],
      "Resource": "arn:aws:ssm:{{REGION}}:{{ACCOUNT_ID}}:parameter/myapp/*" },
    { "Sid": "KmsDecryptViaSsm", "Effect": "Allow",
      "Action": "kms:Decrypt", "Resource": "*",
      "Condition": { "StringEquals": { "kms:ViaService": "ssm.{{REGION}}.amazonaws.com" } } },
    { "Sid": "S3BucketList", "Effect": "Allow",
      "Action": "s3:ListBucket", "Resource": "arn:aws:s3:::{{S3_BUCKET}}" },
    { "Sid": "S3ObjectRW", "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::{{S3_BUCKET}}/*" }
  ]
}
```

The `kms:Decrypt` is scoped by `kms:ViaService: ssm.<region>.amazonaws.com` — the user can only decrypt *through SSM*, not arbitrary KMS keys. Required, or SecureString reads fail with AccessDenied.

### Idempotent setup script

`deploy/aws/setup.sh` renders the template and creates-or-updates everything. Run once with an admin/bootstrap profile:

```bash
AWS_REGION=us-east-1 S3_BUCKET=myapp-prod-files bash deploy/aws/setup.sh
```

```bash
#!/usr/bin/env bash
set -euo pipefail
: "${AWS_REGION:?}"; : "${S3_BUCKET:?}"
USER_NAME="${USER_NAME:-myapp-prod-app}"; POLICY_NAME="${POLICY_NAME:-myapp-prod-app}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# 1. Render policy from {{TOKENS}}
sed -e "s/{{REGION}}/${AWS_REGION}/g" -e "s/{{ACCOUNT_ID}}/${ACCOUNT_ID}/g" \
    -e "s/{{S3_BUCKET}}/${S3_BUCKET}/g" "${HERE}/myapp-app-policy.json" > /tmp/app-policy.json

# 2. Create-or-update the managed policy (new version if it exists)
if aws iam get-policy --policy-arn "${POLICY_ARN}" >/dev/null 2>&1; then
  aws iam create-policy-version --policy-arn "${POLICY_ARN}" \
    --policy-document file:///tmp/app-policy.json --set-as-default >/dev/null
else
  aws iam create-policy --policy-name "${POLICY_NAME}" \
    --policy-document file:///tmp/app-policy.json >/dev/null
fi

# 3. User + attach
aws iam get-user --user-name "${USER_NAME}" >/dev/null 2>&1 || aws iam create-user --user-name "${USER_NAME}" >/dev/null
aws iam attach-user-policy --user-name "${USER_NAME}" --policy-arn "${POLICY_ARN}"

# 4. Private bucket (us-east-1 special-cases LocationConstraint)
if ! aws s3api head-bucket --bucket "${S3_BUCKET}" 2>/dev/null; then
  if [ "${AWS_REGION}" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "${S3_BUCKET}" --region "${AWS_REGION}" >/dev/null
  else
    aws s3api create-bucket --bucket "${S3_BUCKET}" --region "${AWS_REGION}" \
      --create-bucket-configuration "LocationConstraint=${AWS_REGION}" >/dev/null
  fi
  aws s3api put-public-access-block --bucket "${S3_BUCKET}" \
    --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
fi

# 5. Mint a key — encrypt into Varlock (secrets-ssm.md), never commit
aws iam create-access-key --user-name "${USER_NAME}" \
  --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text
```

The minted access key becomes the app's `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` — store it in Varlock locally and seed it into SSM/Kamal bootstrap per `secrets-ssm.md`. (Optional hardening, when relevant: bucket versioning + a noncurrent-version expiry lifecycle rule + SSE-S3 `AES256` default encryption — `market_my_spec`'s bucket bootstrap enables all three.)

---

## 3. ExAws Integration

### Dependencies

```elixir
{:ex_aws, "~> 2.5"},
{:ex_aws_s3, "~> 2.5"},
{:sweet_xml, "~> 0.7"}
```

### Credential chain

ExAws resolves credentials in order:
1. `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` env vars
2. EKS Pod Identity
3. EC2/ECS instance role

> **Hetzner (off-EC2):** there is no instance role available, so the long-lived IAM user key pair (#1) is the only option — set `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` via Kamal's `env.secret` (the same pair that bootstraps SSM at boot). The container then uses that one identity for both S3 and SSM.

For local dev with `~/.aws/credentials` profiles, add `{:configparser_ex, "~> 4.0"}` and:
```elixir
config :ex_aws,
  access_key_id: [{:system, "AWS_ACCESS_KEY_ID"}, {:awscli, "default", 30}],
  secret_access_key: [{:system, "AWS_SECRET_ACCESS_KEY"}, {:awscli, "default", 30}]
```

### Runtime config

```elixir
# config/runtime.exs
config :ex_aws, region: env!("AWS_REGION", :string, "us-east-1")

config :myapp, MyApp.Storage,
  bucket: env!("S3_BUCKET", :string, "myproject-uploads"),
  region: env!("AWS_REGION", :string, "us-east-1")
```

### Storage module pattern

```elixir
defmodule MyApp.Storage.S3 do
  @behaviour MyApp.Storage

  def store(binary, opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "files")
    content_type = Keyword.get(opts, :content_type, "application/octet-stream")
    key = "#{prefix}/#{uuid()}.#{extension(content_type)}"

    case bucket()
         |> ExAws.S3.put_object(key, binary, content_type: content_type)
         |> ExAws.request() do
      {:ok, _} -> {:ok, key}
      {:error, reason} -> {:error, reason}
    end
  end

  defp config, do: Application.get_env(:myapp, MyApp.Storage, [])
  defp bucket, do: config()[:bucket] || "myproject-uploads"
end
```

### Test config

```elixir
# config/test.exs
config :myapp, MyApp.Storage,
  impl: MyApp.Storage.Local,
  test_dir: Path.join(System.tmp_dir!(), "myapp_test_uploads")
```

---

## 4. Presigned URLs (direct browser upload)

```elixir
def presigned_upload_url(key, content_type, expires_in \\ 300) do
  config = ExAws.Config.new(:s3)
  ExAws.S3.presigned_url(config, :put, bucket(), key,
    expires_in: expires_in,
    query_params: [{"Content-Type", content_type}]
  )
end
```

Only relevant if moving from server-side uploads to direct browser-to-S3 uploads.

---

## 5. Troubleshooting

**403 Forbidden** — IAM policy doesn't grant the action. Check resource ARN matches bucket name.

```bash
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::ACCOUNT_ID:user/myproject-app-prod \
  --action-names s3:PutObject \
  --resource-arns "arn:aws:s3:::myproject-uploads/*"
```

**NoCredentialProviders** — No env vars found. Check Dotenvy is loading and `Storage.Local` is used in dev/test.

**NoSuchBucket** — Bucket name in `S3_BUCKET` doesn't match. Verify:
```bash
aws s3api list-buckets --query "Buckets[?starts_with(Name, 'myproject')]"
```

**Region mismatch** — `AWS_REGION` doesn't match bucket location:
```bash
aws s3api get-bucket-location --bucket myproject-uploads
```

---

## Sources

- [ExAws GitHub](https://github.com/ex-aws/ex_aws)
- [ExAws.S3 HexDocs](https://hexdocs.pm/ex_aws_s3/ExAws.S3.html)
- [AWS IAM S3 policy examples](https://docs.aws.amazon.com/AmazonS3/latest/userguide/security_iam_id-based-policy-examples.html)
- [AWS S3 CORS](https://docs.aws.amazon.com/AmazonS3/latest/userguide/enabling-cors-examples.html)
- [AWS S3 blocking public access](https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html)
- [AWS IAM manage access keys](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_access-keys.html)
