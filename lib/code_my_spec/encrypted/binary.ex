defmodule CodeMySpec.Encrypted.Binary do
  @moduledoc false
  use Boundary, top_level?: true, deps: [CodeMySpec.Vault], exports: :all

  use Cloak.Ecto.Binary, vault: CodeMySpec.Vault
end
