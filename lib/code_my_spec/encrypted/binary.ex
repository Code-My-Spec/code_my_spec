defmodule CodeMySpec.Encrypted.Binary do
  @moduledoc false
  use Cloak.Ecto.Binary, vault: CodeMySpec.Vault
end
