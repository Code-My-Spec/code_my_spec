# QA seed for story 814: sets up a test project with a known deploy_key
# so the /app/users LiveView can be tested against dev.codemyspec.com
#
# The project: qa-604-1779069053@example.com / project 616c8e35-7aea-440a-a572-c67dca2455fb
# The dev.env DEPLOY_KEY for localhost:4000 / dev.codemyspec.com:
# 6fc8a6e26353b21b332ce537ed427175ef3af8e2cad73a834095d1e1e8918062e42b6aa8c27f5d8f47246574c82b2d3a17248db692906f6f1bcbfd7b754286c9

import Ecto.Changeset
alias CodeMySpec.Repo
alias CodeMySpec.Projects.Project

project_id = "616c8e35-7aea-440a-a572-c67dca2455fb"
deploy_key = "6fc8a6e26353b21b332ce537ed427175ef3af8e2cad73a834095d1e1e8918062e42b6aa8c27f5d8f47246574c82b2d3a17248db692906f6f1bcbfd7b754286c9"
client_api_url = "https://dev.codemyspec.com"

project = Repo.get!(Project, project_id)

# Set only deploy_key (+ its blind-index hash) and client_api_url. We avoid
# Projects.update_project/3 / Project.changeset/3 because those overwrite
# account_id from a Scope; a minimal changeset keeps the existing project intact
# while still encrypting deploy_key (Cloak Ecto type on dump).
project
|> cast(%{deploy_key: deploy_key, client_api_url: client_api_url}, [:deploy_key, :client_api_url])
|> put_change(:deploy_key_hash, Project.hash_deploy_key(deploy_key))
|> Repo.update()
|> case do
  {:ok, updated} ->
    IO.puts("OK: project #{project_id} updated")
    IO.puts("  client_api_url: #{updated.client_api_url}")
    IO.puts("  deploy_key_hash: #{updated.deploy_key_hash}")

  {:error, changeset} ->
    IO.puts("ERROR: #{inspect(changeset.errors)}")
end
