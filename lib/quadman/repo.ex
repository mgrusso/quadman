defmodule Quadman.Repo do
  use Ecto.Repo,
    otp_app: :quadman,
    adapter: Ecto.Adapters.SQLite3
end
