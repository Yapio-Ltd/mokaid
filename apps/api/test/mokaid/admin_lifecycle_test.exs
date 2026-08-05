defmodule Mokaid.AdminLifecycleTest do
  use Mokaid.DataCase, async: true

  alias Mokaid.Admin
  alias Mokaid.Accounts
  alias Mokaid.Accounts.User
  alias Mokaid.Billing
  alias Mokaid.Repo

  setup do
    Billing.seed_plans()
    {workspace, _owner} = workspace_fixture()

    admin =
      user_fixture(%{email: "admin#{System.unique_integer([:positive])}@example.com"})
      |> then(fn u ->
        u |> Ecto.Changeset.change(is_platform_admin: true) |> Repo.update!()
      end)

    target = user_fixture(%{email: "user#{System.unique_integer([:positive])}@example.com"})

    {:ok, workspace: workspace, admin: admin, target: target}
  end

  test "metrics includes cost and margin fields", %{admin: _} do
    m = Admin.metrics()
    assert is_integer(m.users_total)
    assert Map.has_key?(m, :provider_cost_mtd_cents)
    assert Map.has_key?(m, :gross_margin_cents)
    assert Map.has_key?(m, :users_banned)
  end

  test "ban and unban user", %{admin: admin, target: target} do
    assert {:ok, banned} = Admin.ban_user(target, admin, %{"reason" => "abuse"})
    assert banned.status == "suspended"
    assert banned.ban_reason == "abuse"
    refute User.active?(banned)

    assert {:ok, active} = Admin.unban_user(banned, admin)
    assert active.status == "active"
    assert User.active?(active)
  end

  test "cannot ban self", %{admin: admin} do
    assert {:error, :cannot_target_self} = Admin.ban_user(admin, admin, %{"reason" => "x"})
  end

  test "schedule and cancel deletion", %{admin: admin, target: target} do
    assert {:ok, scheduled} =
             Admin.schedule_user_deletion(target, admin, %{"reason" => "gdpr", "days" => 30})

    assert scheduled.deletion_scheduled_at
    assert scheduled.status == "suspended"

    assert {:ok, cancelled} = Admin.cancel_user_deletion(scheduled, admin)
    assert is_nil(cancelled.deletion_scheduled_at)
  end

  test "adjust credits is transactional with reason", %{admin: admin, workspace: workspace} do
    assert {:ok, sub} =
             Admin.adjust_credits(workspace.id, 100, admin,
               reason: "promo support",
               idempotency_key: "test-key-1"
             )

    assert sub.credits_balance >= 100

    # Idempotent replay
    assert {:ok, sub2} =
             Admin.adjust_credits(workspace.id, 100, admin,
               reason: "promo support",
               idempotency_key: "test-key-1"
             )

    assert sub2.credits_balance == sub.credits_balance
  end

  test "authenticate rejects suspended users", %{target: target} do
    {:ok, banned} =
      target
      |> User.moderation_changeset(%{status: "suspended", banned_at: DateTime.utc_now()})
      |> Repo.update()

    assert {:error, :inactive} =
             Accounts.authenticate_by_password(banned.email, "test-password-1234")
  end
end
