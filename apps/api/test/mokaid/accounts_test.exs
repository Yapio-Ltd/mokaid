defmodule Mokaid.AccountsTest do
  use Mokaid.DataCase, async: true

  alias Mokaid.Accounts
  alias Mokaid.Accounts.User

  test "change_password updates hash when current password is valid" do
    user = user_fixture(%{password: "old-password-1234"})

    assert {:ok, updated} =
             Accounts.change_password(user, %{
               "current_password" => "old-password-1234",
               "password" => "new-password-5678",
               "password_confirmation" => "new-password-5678"
             })

    assert User.has_password?(updated)
    assert User.valid_password?(updated, "new-password-5678")
    refute User.valid_password?(updated, "old-password-1234")
  end

  test "change_password rejects incorrect current password" do
    user = user_fixture(%{password: "old-password-1234"})

    assert {:error, changeset} =
             Accounts.change_password(user, %{
               "current_password" => "wrong-password",
               "password" => "new-password-5678",
               "password_confirmation" => "new-password-5678"
             })

    assert %{current_password: ["is incorrect"]} = errors_on(changeset)
  end

  test "change_password rejects mismatched confirmation" do
    user = user_fixture(%{password: "old-password-1234"})

    assert {:error, changeset} =
             Accounts.change_password(user, %{
               "current_password" => "old-password-1234",
               "password" => "new-password-5678",
               "password_confirmation" => "different-password"
             })

    assert %{password_confirmation: _} = errors_on(changeset)
  end

  test "change_password rejects oauth-only users" do
    {:ok, user} =
      Accounts.register_user(%{
        email: "oauth#{System.unique_integer([:positive])}@example.com",
        full_name: "OAuth User",
        cognito_sub: "cognito-sub-#{System.unique_integer([:positive])}"
      })

    refute User.has_password?(user)

    assert {:error, :oauth_only} =
             Accounts.change_password(user, %{
               "current_password" => "anything",
               "password" => "new-password-5678",
               "password_confirmation" => "new-password-5678"
             })
  end

  test "login_or_register_with_google creates user and workspace" do
    email = "google#{System.unique_integer([:positive])}@example.com"

    assert {:ok, user, :created, workspace} =
             Accounts.login_or_register_with_google(%{
               sub: "google-sub-#{System.unique_integer([:positive])}",
               email: email,
               name: "Google User",
               picture: "https://example.com/a.png"
             })

    refute User.has_password?(user)
    assert user.email == email
    assert user.avatar_url == "https://example.com/a.png"
    assert String.starts_with?(user.cognito_sub, "google:")
    assert workspace.name =~ "Google"
  end

  test "login_or_register_with_google reuses existing email account" do
    user = user_fixture(%{email: "linked#{System.unique_integer([:positive])}@example.com"})

    assert {:ok, same, :existing, nil} =
             Accounts.login_or_register_with_google(%{
               sub: "google-sub-#{System.unique_integer([:positive])}",
               email: user.email,
               name: "Linked",
               picture: nil
             })

    assert same.id == user.id
    assert String.starts_with?(same.cognito_sub, "google:")
  end
end
