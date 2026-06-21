defmodule Mix.Tasks.ProdIssues.Pull do
  @moduledoc """
  One-shot ops script: pull framework-scoped incoming issues from prod
  (`https://codemyspec.com`) into the local dev Postgres so they can be
  triaged in dev without context-switching CLIs.

  Reads the prod OAuth token from `~/.codemyspec/prod_token`. The file
  may contain either:

  - a plaintext bearer token (manually pasted), or
  - the raw encrypted blob lifted from `cli.db`'s `client_users.oauth_token`
    column — the script detects the Cloak tag (`AES.GCM.V1`) and
    decrypts via the shared vault.

  Easiest setup — use `hex()` so sqlite3 doesn't truncate the BLOB at
  the first null byte:

      sqlite3 ~/.codemyspec/cli.db \\
        "SELECT hex(oauth_token) FROM client_users WHERE email='you@example.com';" \\
        > ~/.codemyspec/prod_token
      chmod 600 ~/.codemyspec/prod_token

  The token expires hourly; the running `cms server` (prod_cli) refreshes
  its own copy on its own cadence — re-extract when the script 401s.

  Issues are inserted into the `code_my_spec_dev` `issues` table with
  `id` preserved from prod and `project_id` / `account_id` rewritten to
  point at the local dev CodeMySpec project. Duplicates (same `id`) are
  skipped via `ON CONFLICT DO NOTHING` — safe to run repeatedly.

  This is a hack to give the founder visibility into prod framework
  friction during local dev. Not a product feature. Dispositions on
  pulled issues land in dev only; prod stays as-is and drifts. Manual
  cleanup on prod is on you.

  ## Usage

      echo "$PROD_TOKEN" > ~/.codemyspec/prod_token
      chmod 600 ~/.codemyspec/prod_token
      mix prod_issues.pull
  """

  use Boundary, classify_to: CodeMySpec
  use Mix.Task


  @prod_url "https://codemyspec.com"
  @token_path "~/.codemyspec/prod_token"

  # Dev's CodeMySpec project — pulled prod issues land under this
  # project/account so the existing dev triage flow picks them up.
  @dev_project_id "708492f9-454e-482f-a2eb-be64f0356b87"
  @dev_account_id "0f27281c-240b-4d6d-8e52-9c5972329522"

  @shortdoc "Pull framework-scoped incoming issues from prod into dev"

  def run(_args) do
    Mix.Task.run("app.start")

    token = read_token!()
    issues = fetch_remote_issues!(token)

    {inserted, skipped} =
      Enum.reduce(issues, {0, 0}, fn data, {ins, skip} ->
        case insert_issue(data) do
          {:ok, 1} -> {ins + 1, skip}
          {:ok, 0} -> {ins, skip + 1}
        end
      end)

    Mix.shell().info(
      "Pulled #{length(issues)} prod framework issues: " <>
        "#{inserted} new, #{skipped} already in dev."
    )
  end

  defp read_token! do
    path = Path.expand(@token_path)

    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.trim()
        |> maybe_unhex()
        |> maybe_decrypt()

      {:error, :enoent} ->
        Mix.shell().error("""
        No prod token at #{path}. Create it:

          sqlite3 ~/.codemyspec/cli.db \\
            "SELECT hex(oauth_token) FROM client_users LIMIT 1;" > #{path}
          chmod 600 #{path}
        """)

        System.halt(1)
    end
  end

  # SQLite truncates BLOBs at the first null byte when emitting as text,
  # so the recommended dump uses hex(...). If the file is all hex chars
  # and even-length, decode it back to a binary blob. Otherwise pass
  # through (plaintext token).
  defp maybe_unhex(content) do
    if hex_string?(content) do
      Base.decode16!(content, case: :mixed)
    else
      content
    end
  end

  defp hex_string?(s) do
    rem(byte_size(s), 2) == 0 and byte_size(s) > 0 and
      Regex.match?(~r/\A[0-9A-Fa-f]+\z/, s)
  end

  # The cli.db blob is Cloak-encrypted. Always try to decrypt; if it
  # succeeds, return the plaintext. If it fails AND the input looks
  # like a plain bearer token (printable ASCII), pass it through.
  defp maybe_decrypt(blob) do
    case CodeMySpec.Vault.decrypt(blob) do
      {:ok, plaintext} ->
        String.trim(plaintext)

      {:error, _reason} ->
        if String.printable?(blob) do
          String.trim(blob)
        else
          Mix.shell().error("Token file is neither a Cloak-encrypted blob nor printable plaintext.")
          System.halt(1)
        end
    end
  end

  defp fetch_remote_issues!(token) do
    req =
      Req.new(
        base_url: @prod_url,
        headers: [authorization: "Bearer #{token}"],
        decode_json: [keys: :strings]
      )

    case Req.get(req,
           url: "/api/issues",
           params: [status: "incoming", scope: "framework"]
         ) do
      {:ok, %{status: 200, body: %{"data" => data}}} ->
        data

      {:ok, %{status: 401}} ->
        Mix.shell().error("""
        Prod returned 401 — token expired or invalid. Re-extract:

          sqlite3 ~/.codemyspec/cli.db \\
            "SELECT hex(oauth_token) FROM client_users LIMIT 1;" \\
            > #{Path.expand(@token_path)}

        If that's still expired, the prod `cms server` (:4003) needs to
        refresh first — make any outbound call from it (e.g. open the
        dashboard at https://dev.codemyspec.com/issues, which the cms
        server proxies through).
        """)

        System.halt(1)

      {:ok, %{status: status, body: body}} ->
        Mix.shell().error("Prod returned #{status}: #{inspect(body)}")
        System.halt(1)

      {:error, reason} ->
        Mix.shell().error("Prod request failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp insert_issue(data) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    sql = """
    INSERT INTO issues (
      id, title, severity, scope, description, status,
      source, story_id, source_path, category,
      project_id, account_id, attachments,
      inserted_at, updated_at
    )
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13::jsonb, $14, $15)
    ON CONFLICT (id) DO NOTHING
    """

    params = [
      uuid_dump(data["id"]),
      data["title"],
      data["severity"],
      data["scope"],
      data["description"],
      data["status"],
      data["source"] || "prod_pull",
      # story_id deliberately dropped — prod's story ids don't map to dev's
      nil,
      data["source_path"],
      data["category"],
      uuid_dump(@dev_project_id),
      uuid_dump(@dev_account_id),
      Jason.encode!(data["attachments"] || []),
      now,
      now
    ]

    result = Ecto.Adapters.SQL.query!(CodeMySpec.Repo, sql, params)
    {:ok, result.num_rows}
  end

  defp uuid_dump(uuid_string) do
    {:ok, raw} = Ecto.UUID.dump(uuid_string)
    raw
  end
end
