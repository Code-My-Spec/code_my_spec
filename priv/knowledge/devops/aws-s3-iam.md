# AWS S3 and IAM Setup for Phoenix/Elixir

Practical reference for creating S3 buckets, scoped IAM users, and wiring up ExAws in an Elixir application. Covers prod/UAT multi-environment setup, exact CLI commands, and JSON policy documents.

## Prerequisites

Install and authenticate the AWS CLI with admin credentials before running any commands below. The admin credentials are only used during initial setup — the app itself uses a dedicated, least-privilege IAM user.

```bash
# Install AWS CLI (macOS)
brew install awscli

# Configure with your admin credentials
aws configure
# AWS Access Key ID: <your admin key>
# AWS Secret Access Key: <your admin secret>
# Default region name: us-east-1
# Default output format: json

# Verify authentication
aws sts get-caller-identity
```

---

## 1. S3 Bucket Creation

### Naming conventions

Use environment suffixes to keep buckets separate. Bucket names are globally unique across all AWS accounts, so use a project prefix.

| Environment | Bucket name                  |
|-------------|------------------------------|
| prod        | `fuellytics-uploads`         |
| uat         | `fuellytics-uploads-uat`     |
| dev         | local disk (no S3 bucket)    |

### Create the buckets

```bash
# Production bucket
aws s3api create-bucket \
  --bucket fuellytics-uploads \
  --region us-east-1

# UAT bucket
aws s3api create-bucket \
  --bucket fuellytics-uploads-uat \
  --region us-east-1
```

Note: `us-east-1` does not accept a `--create-bucket-configuration` flag — it is the default region. For any other region, add:
```bash
--create-bucket-configuration LocationConstraint=eu-central-1
```

### Block all public access

Photos are private objects served only by the application. Never make this bucket public.

```bash
aws s3api put-public-access-block \
  --bucket fuellytics-uploads \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

aws s3api put-public-access-block \
  --bucket fuellytics-uploads-uat \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```

### Verify the bucket configuration

```bash
aws s3api get-bucket-location --bucket fuellytics-uploads
aws s3api get-public-access-block --bucket fuellytics-uploads
```

### Optional: lifecycle policy to expire old objects

If you store temporary verification photos and want to clean up after 90 days, add a lifecycle policy. Save as `lifecycle.json`:

```json
{
  "Rules": [
    {
      "ID": "expire-old-photos",
      "Status": "Enabled",
      "Filter": {
        "Prefix": "files/"
      },
      "Expiration": {
        "Days": 90
      }
    }
  ]
}
```

```bash
aws s3api put-bucket-lifecycle-configuration \
  --bucket fuellytics-uploads \
  --lifecycle-configuration file://lifecycle.json
```

### CORS configuration

CORS is only needed if you upload directly from the browser (e.g., presigned PUT URLs from a frontend). If uploads go through the Phoenix server, skip this.

For direct browser uploads (presigned URLs), save as `cors.json`:

```json
[
  {
    "AllowedHeaders": ["*"],
    "AllowedMethods": ["GET", "PUT", "POST", "HEAD"],
    "AllowedOrigins": [
      "https://fuellytics.app",
      "https://uat.fuellytics.app"
    ],
    "ExposeHeaders": ["ETag"],
    "MaxAgeSeconds": 3000
  }
]
```

For development, add your local origin:
```json
[
  {
    "AllowedHeaders": ["*"],
    "AllowedMethods": ["GET", "PUT", "POST", "HEAD"],
    "AllowedOrigins": [
      "https://fuellytics.app",
      "https://uat.fuellytics.app",
      "https://dev.fuellytics.app",
      "http://localhost:4000"
    ],
    "ExposeHeaders": ["ETag"],
    "MaxAgeSeconds": 3000
  }
]
```

Apply the CORS config:

```bash
aws s3api put-bucket-cors \
  --bucket fuellytics-uploads \
  --cors-configuration file://cors.json

# Verify
aws s3api get-bucket-cors --bucket fuellytics-uploads
```

Note: If uploads go through the Phoenix server (the current `Storage.S3` module does server-side uploads), CORS on the bucket is not required. CORS only applies to browser-to-S3 direct uploads.

---

## 2. IAM User Creation

Create a dedicated IAM user for the application. This user gets only the permissions it needs — no console access, no other AWS services.

### Create one IAM user per environment

```bash
# Production app user
aws iam create-user --user-name fuellytics-app-prod

# UAT app user
aws iam create-user --user-name fuellytics-app-uat
```

### Create the S3 policy document

The policy grants the minimum actions needed: list, read, write, and delete objects in the specific bucket. Save as `s3-policy-prod.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListBucket",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": "arn:aws:s3:::fuellytics-uploads"
    },
    {
      "Sid": "ObjectOperations",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      "Resource": "arn:aws:s3:::fuellytics-uploads/*"
    }
  ]
}
```

For UAT, save as `s3-policy-uat.json` with `fuellytics-uploads-uat` in the ARNs:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListBucket",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": "arn:aws:s3:::fuellytics-uploads-uat"
    },
    {
      "Sid": "ObjectOperations",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      "Resource": "arn:aws:s3:::fuellytics-uploads-uat/*"
    }
  ]
}
```

### Create and attach managed policies

```bash
# Create the prod policy in AWS
aws iam create-policy \
  --policy-name fuellytics-s3-prod \
  --policy-document file://s3-policy-prod.json

# Attach it to the prod user (replace 123456789012 with your AWS account ID)
aws iam attach-user-policy \
  --user-name fuellytics-app-prod \
  --policy-arn arn:aws:iam::123456789012:policy/fuellytics-s3-prod

# Create and attach the UAT policy
aws iam create-policy \
  --policy-name fuellytics-s3-uat \
  --policy-document file://s3-policy-uat.json

aws iam attach-user-policy \
  --user-name fuellytics-app-uat \
  --policy-arn arn:aws:iam::123456789012:policy/fuellytics-s3-uat
```

Retrieve your account ID if you don't have it:
```bash
aws sts get-caller-identity --query Account --output text
```

### Verify the policy attachment

```bash
aws iam list-attached-user-policies --user-name fuellytics-app-prod
```

### Generate access keys

Access keys are the credentials that go into the server environment files. The secret is only shown once — copy it immediately.

```bash
# Generate prod access key
aws iam create-access-key --user-name fuellytics-app-prod

# Generate UAT access key
aws iam create-access-key --user-name fuellytics-app-uat
```

Response format:
```json
{
  "AccessKey": {
    "UserName": "fuellytics-app-prod",
    "AccessKeyId": "AKIAIOSFODNN7EXAMPLE",
    "Status": "Active",
    "SecretAccessKey": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    "CreateDate": "2024-01-15T12:00:00Z"
  }
}
```

Store `AccessKeyId` and `SecretAccessKey` in the server's env file (`/opt/fuellytics/prod.env`). Never put them in the repo.

### Rotate access keys

Keys should be rotated periodically. Create a new key before deleting the old one to avoid downtime:

```bash
# Create a new key first
aws iam create-access-key --user-name fuellytics-app-prod

# After updating the server env with the new key, delete the old one
aws iam delete-access-key \
  --user-name fuellytics-app-prod \
  --access-key-id AKIAIOSFODNN7EXAMPLE

# List all keys for a user
aws iam list-access-keys --user-name fuellytics-app-prod
```

---

## 3. ExAws Integration

### Dependencies

The project already has these in `mix.exs`:

```elixir
{:ex_aws, "~> 2.5"},
{:ex_aws_s3, "~> 2.5"},
{:sweet_xml, "~> 0.7"}   # required for list_objects and some S3 XML responses
```

ExAws uses `Req` as its HTTP client as of v2.5.0 (replacing hackney). No additional HTTP dependency is needed.

### Credential chain

ExAws resolves credentials in this order by default:

1. `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` environment variables
2. EKS Pod Identity (when running on EKS with Pod Identity configured)
3. EC2/ECS instance role (when running on AWS infrastructure)

The default configuration (implicit — you do not need to write this):

```elixir
config :ex_aws,
  access_key_id: [{:system, "AWS_ACCESS_KEY_ID"}, :pod_identity, :instance_role],
  secret_access_key: [{:system, "AWS_SECRET_ACCESS_KEY"}, :pod_identity, :instance_role]
```

For local development using `~/.aws/credentials` profiles, add the `configparser_ex` dependency and extend the chain:

```elixir
# mix.exs — only needed if using ~/.aws/credentials profiles
{:configparser_ex, "~> 4.0"}
```

```elixir
# config/config.exs — only if you need awscli profile fallback
config :ex_aws,
  access_key_id: [
    {:system, "AWS_ACCESS_KEY_ID"},
    {:awscli, "default", 30}
  ],
  secret_access_key: [
    {:system, "AWS_SECRET_ACCESS_KEY"},
    {:awscli, "default", 30}
  ]
```

For a named profile (e.g., `fuellytics-dev`):

```elixir
config :ex_aws,
  access_key_id: [{:system, "AWS_ACCESS_KEY_ID"}, {:awscli, "fuellytics-dev", 30}],
  secret_access_key: [{:system, "AWS_SECRET_ACCESS_KEY"}, {:awscli, "fuellytics-dev", 30}]
```

The third element in `{:awscli, profile, timeout}` is the timeout in seconds for credential refresh.

### Region configuration

Region is set in `runtime.exs` and loaded from the environment:

```elixir
# config/runtime.exs
config :ex_aws,
  region: env!("AWS_REGION", :string, "us-east-1")

config :fuellytics, Fuellytics.Storage,
  bucket: env!("S3_BUCKET", :string, "fuellytics-uploads"),
  region: env!("AWS_REGION", :string, "us-east-1")
```

### Environment variable setup

In the server env files (`/opt/fuellytics/prod.env` and `/opt/fuellytics/uat.env`):

```bash
# prod.env
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
AWS_REGION=us-east-1
S3_BUCKET=fuellytics-uploads

# uat.env
AWS_ACCESS_KEY_ID=AKIAI...UAT_KEY
AWS_SECRET_ACCESS_KEY=...UAT_SECRET...
AWS_REGION=us-east-1
S3_BUCKET=fuellytics-uploads-uat
```

For local development, add to `envs/dev.env` (gitignored):

```bash
AWS_ACCESS_KEY_ID=AKIAI...DEV_KEY
AWS_SECRET_ACCESS_KEY=...DEV_SECRET...
AWS_REGION=us-east-1
S3_BUCKET=fuellytics-uploads-dev
```

Note: The `Storage.Local` backend is used in dev by default (see `config/dev.exs`). Only set AWS credentials in `dev.env` if you want to test against a real S3 bucket in development.

### How the Storage module uses ExAws

The `Fuellytics.Storage.S3` backend calls ExAws directly. No credentials appear in application config — they come from the environment:

```elixir
# lib/fuellytics/storage/s3.ex
defmodule Fuellytics.Storage.S3 do
  @behaviour Fuellytics.Storage

  def store(binary, opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "files")
    content_type = Keyword.get(opts, :content_type, "application/octet-stream")
    ext = extension(content_type)
    key = "#{prefix}/#{uuid()}.#{ext}"

    case bucket()
         |> ExAws.S3.put_object(key, binary, content_type: content_type)
         |> ExAws.request() do
      {:ok, _} -> {:ok, key}
      {:error, reason} -> {:error, reason}
    end
  end

  def fetch(key) do
    case bucket()
         |> ExAws.S3.get_object(key)
         |> ExAws.request() do
      {:ok, %{body: body}} -> {:ok, body}
      {:error, {:http_error, 404, _}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def delete(key) do
    case bucket()
         |> ExAws.S3.delete_object(key)
         |> ExAws.request() do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def url(key) do
    "https://#{bucket()}.s3.#{region()}.amazonaws.com/#{key}"
  end

  defp config, do: Application.get_env(:fuellytics, Fuellytics.Storage, [])
  defp bucket, do: config()[:bucket] || "fuellytics-uploads"
  defp region, do: config()[:region] || "us-east-1"
end
```

### Presigned URLs (direct browser upload)

If you want the browser to upload directly to S3 without going through Phoenix, generate a presigned PUT URL on the server:

```elixir
def presigned_upload_url(key, content_type, expires_in \\ 300) do
  config = ExAws.Config.new(:s3)

  ExAws.S3.presigned_url(
    config,
    :put,
    bucket(),
    key,
    expires_in: expires_in,
    query_params: [{"Content-Type", content_type}]
  )
  # Returns {:ok, "https://bucket.s3.amazonaws.com/key?X-Amz-..."}
end
```

The current implementation uploads through Phoenix (the PWA sends the photo to the Phoenix controller, which calls `Storage.store/2`). Presigned URLs are only relevant if you later move to direct browser-to-S3 uploads.

### Test configuration

Tests use `Storage.Local` to avoid any S3 calls:

```elixir
# config/test.exs
config :fuellytics, Fuellytics.Storage,
  impl: Fuellytics.Storage.Local,
  test_dir: Path.join(System.tmp_dir!(), "fuellytics_test_uploads")
```

No AWS credentials are needed to run the test suite.

---

## 4. Multi-Environment Setup

### Bucket-per-environment pattern

Each deployed environment (prod, UAT) gets its own bucket and its own IAM user. This prevents UAT activity from polluting prod data and allows bucket policies to be tuned per environment.

```
Bucket                      IAM user                 Environment
fuellytics-uploads          fuellytics-app-prod      prod
fuellytics-uploads-uat      fuellytics-app-uat       uat
(local disk)                (none)                   dev
```

### Verifying isolation

Each IAM user can only access its own bucket. Verify this:

```bash
# This should succeed (prod user accessing prod bucket)
AWS_ACCESS_KEY_ID=<prod-key> AWS_SECRET_ACCESS_KEY=<prod-secret> \
  aws s3 ls s3://fuellytics-uploads

# This should fail with AccessDenied (prod user cannot access UAT bucket)
AWS_ACCESS_KEY_ID=<prod-key> AWS_SECRET_ACCESS_KEY=<prod-secret> \
  aws s3 ls s3://fuellytics-uploads-uat
```

### Configuration summary

| Setting                 | prod.env                         | uat.env                              |
|-------------------------|----------------------------------|--------------------------------------|
| `AWS_ACCESS_KEY_ID`     | prod IAM user key                | uat IAM user key                     |
| `AWS_SECRET_ACCESS_KEY` | prod IAM user secret             | uat IAM user secret                  |
| `AWS_REGION`            | `us-east-1`                      | `us-east-1`                          |
| `S3_BUCKET`             | `fuellytics-uploads`             | `fuellytics-uploads-uat`             |

---

## 5. Complete Setup Checklist

Run through this when provisioning a new environment:

```bash
# 1. Create the bucket
aws s3api create-bucket --bucket fuellytics-uploads --region us-east-1

# 2. Block all public access
aws s3api put-public-access-block \
  --bucket fuellytics-uploads \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# 3. Create the IAM user
aws iam create-user --user-name fuellytics-app-prod

# 4. Write the policy document to s3-policy-prod.json (see Section 2 above)

# 5. Create the managed policy
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws iam create-policy \
  --policy-name fuellytics-s3-prod \
  --policy-document file://s3-policy-prod.json

# 6. Attach the policy to the user
aws iam attach-user-policy \
  --user-name fuellytics-app-prod \
  --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/fuellytics-s3-prod

# 7. Generate access keys
aws iam create-access-key --user-name fuellytics-app-prod
# Copy AccessKeyId and SecretAccessKey to /opt/fuellytics/prod.env

# 8. Verify the bucket and credentials work
AWS_ACCESS_KEY_ID=<new-key> AWS_SECRET_ACCESS_KEY=<new-secret> \
  aws s3 ls s3://fuellytics-uploads
```

---

## 6. Troubleshooting

### ExAws raises `%ExAws.Error{message: "403 Forbidden"}`

The IAM policy attached to the user does not grant the action being performed. Check:
- `s3:PutObject` is in the policy for writes
- `s3:GetObject` is in the policy for reads
- The resource ARN matches the actual bucket name exactly
- The credentials in the env file match the correct IAM user

```bash
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::123456789012:user/fuellytics-app-prod \
  --action-names s3:PutObject \
  --resource-arns "arn:aws:s3:::fuellytics-uploads/*"
```

### ExAws raises `%ExAws.Error{message: "NoCredentialProviders"}`

No credentials were found in the chain. Verify:
- `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` are set in the process environment
- The env file is being loaded (check `dotenvy` source! config in `runtime.exs`)
- In dev, the Storage impl is set to `Local` so no credentials are needed

### ExAws raises `%ExAws.Error{message: "NoSuchBucket"}`

The bucket name in `S3_BUCKET` does not match the created bucket. Bucket names are case-sensitive and globally unique. Verify:

```bash
aws s3api list-buckets --query "Buckets[?starts_with(Name, 'fuellytics')]"
```

### Region mismatch errors

If `AWS_REGION` is set to a different region than where the bucket was created, requests will fail. Verify:

```bash
aws s3api get-bucket-location --bucket fuellytics-uploads
```

---

## Sources

- [ExAws GitHub — credential chain documentation](https://github.com/ex-aws/ex_aws)
- [ExAws.S3 HexDocs — put_object, get_object, presigned_url](https://hexdocs.pm/ex_aws_s3/ExAws.S3.html)
- [AWS IAM — identity-based policy examples for Amazon S3](https://docs.aws.amazon.com/AmazonS3/latest/userguide/security_iam_id-based-policy-examples.html)
- [AWS S3 — configuring CORS](https://docs.aws.amazon.com/AmazonS3/latest/userguide/enabling-cors-examples.html)
- [AWS S3 — blocking public access](https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html)
- [AWS CLI — create-access-key reference](https://docs.aws.amazon.com/cli/latest/reference/iam/create-access-key.html)
- [AWS IAM — manage access keys for IAM users](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_access-keys.html)
