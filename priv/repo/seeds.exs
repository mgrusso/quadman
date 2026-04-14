alias Quadman.Accounts

email = System.get_env("ADMIN_EMAIL", "admin@quadman.local")
password = System.get_env("ADMIN_PASSWORD", "changeme123!")

case Accounts.get_user_by_email(email) do
  nil ->
    case Accounts.register_user(%{email: email, password: password, role: "admin"}) do
      {:ok, user} ->
        IO.puts("Admin user created: #{user.email}")

      {:error, changeset} ->
        IO.puts("Failed to create admin user: #{inspect(changeset.errors)}")
    end

  _user ->
    IO.puts("Admin user already exists: #{email}")
end
