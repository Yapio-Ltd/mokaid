defmodule Mokaid.Admin do
  @moduledoc """
  Platform-operator queries and mutations (cross-workspace CRM).
  All mutating helpers expect a platform-admin actor and write audit logs.
  """

  import Ecto.Query

  alias Mokaid.Accounts
  alias Mokaid.Accounts.User
  alias Mokaid.Audit.AuditLog
  alias Mokaid.Billing
  alias Mokaid.Billing.{BillingPlan, CreditTransaction, Invoice, Subscription, UsageEvent}
  alias Mokaid.Members
  alias Mokaid.Members.{Member, MemberInvite, Role}
  alias Mokaid.Repo
  alias Mokaid.Workspaces
  alias Mokaid.Workspaces.Workspace

  # ---------- Metrics ----------

  def metrics do
    now = DateTime.utc_now()
    month_ago = DateTime.add(now, -30, :day)

    month_start =
      now
      |> Map.put(:day, 1)
      |> Map.put(:hour, 0)
      |> Map.put(:minute, 0)
      |> Map.put(:second, 0)
      |> Map.put(:microsecond, {0, 6})

    users_total = Repo.aggregate(User, :count)
    users_active = Repo.one(from u in User, where: u.status == "active", select: count(u.id))

    users_banned =
      Repo.one(
        from u in User,
          where: u.status in ["suspended", "disabled"] or not is_nil(u.banned_at),
          select: count(u.id)
      ) || 0

    workspaces_total =
      Repo.one(from w in Workspace, where: is_nil(w.deleted_at), select: count(w.id))

    subs =
      Repo.all(
        from s in Subscription,
          where: s.status in ["active", "past_due"],
          preload: [:plan]
      )

    mrr_cents =
      Enum.reduce(subs, 0, fn sub, acc ->
        plan = sub.plan

        if plan do
          amount =
            case sub.billing_cycle do
              "yearly" -> div(plan.price_cents_yearly || 0, 12)
              _ -> plan.price_cents_monthly || 0
            end

          acc + amount
        else
          acc
        end
      end)

    subs_active = Enum.count(subs, &(&1.status == "active"))
    subs_past_due = Enum.count(subs, &(&1.status == "past_due"))

    invoices_pending =
      Repo.one(from i in Invoice, where: i.status == "pending", select: count(i.id))

    new_users_30d =
      Repo.one(from u in User, where: u.inserted_at >= ^month_ago, select: count(u.id))

    credits_spend_30d =
      Repo.one(
        from t in CreditTransaction,
          where: t.kind == "spend" and t.inserted_at >= ^month_ago,
          select: coalesce(sum(fragment("abs(?)", t.amount)), 0)
      ) || 0

    credits_balance_total =
      Repo.one(
        from s in Subscription,
          where: s.status in ["active", "past_due"],
          select:
            coalesce(
              sum(s.credits_balance + s.included_credits_remaining),
              0
            )
      ) || 0

    internal_ai_cost_mtd_cents =
      Repo.one(
        from e in UsageEvent,
          where: e.occurred_at >= ^month_start,
          select: coalesce(sum(e.cost_cents), 0)
      ) || 0

    cost_mtd = cost_mtd_by_provider(month_start)

    deletions_pending =
      Repo.one(
        from u in User,
          where: not is_nil(u.deletion_scheduled_at) and is_nil(u.anonymized_at),
          select: count(u.id)
      ) || 0

    active_subs = max(subs_active, 1)
    arpu_cents = div(mrr_cents, active_subs)
    arr_cents = mrr_cents * 12
    provider_cost_mtd = Enum.reduce(cost_mtd, 0, fn {_k, v}, acc -> acc + v end)
    gross_margin_cents = mrr_cents - provider_cost_mtd

    %{
      users_total: users_total,
      users_active: users_active || 0,
      users_banned: users_banned,
      workspaces_total: workspaces_total || 0,
      mrr_cents: mrr_cents,
      arr_cents: arr_cents,
      arpu_cents: arpu_cents,
      subscriptions_active: subs_active,
      subscriptions_past_due: subs_past_due,
      invoices_pending: invoices_pending || 0,
      new_users_30d: new_users_30d || 0,
      credits_spend_30d: credits_spend_30d,
      credits_balance_total: credits_balance_total,
      internal_ai_cost_mtd_cents: internal_ai_cost_mtd_cents,
      provider_cost_mtd_cents: provider_cost_mtd,
      openai_cost_mtd_cents: Map.get(cost_mtd, "openai", 0),
      anthropic_cost_mtd_cents: Map.get(cost_mtd, "anthropic", 0),
      aws_cost_mtd_cents: Map.get(cost_mtd, "aws", 0),
      gross_margin_cents: gross_margin_cents,
      deletions_pending: deletions_pending
    }
  end

  def metrics_timeseries(opts \\ %{}) do
    days = min(parse_int(Map.get(opts, "days"), 30), 90)
    since = DateTime.add(DateTime.utc_now(), -days, :day)

    users_by_day =
      Repo.all(
        from u in User,
          where: u.inserted_at >= ^since,
          group_by: fragment("date_trunc('day', ?)", u.inserted_at),
          order_by: fragment("date_trunc('day', ?)", u.inserted_at),
          select: %{
            day: fragment("date_trunc('day', ?)", u.inserted_at),
            count: count(u.id)
          }
      )

    usage_by_day =
      Repo.all(
        from e in UsageEvent,
          where: e.occurred_at >= ^since,
          group_by: fragment("date_trunc('day', ?)", e.occurred_at),
          order_by: fragment("date_trunc('day', ?)", e.occurred_at),
          select: %{
            day: fragment("date_trunc('day', ?)", e.occurred_at),
            cost_cents: coalesce(sum(e.cost_cents), 0),
            events: count(e.id)
          }
      )

    provider_by_day =
      Repo.all(
        from s in Mokaid.Billing.PlatformCostSnapshot,
          where: s.period_start >= ^since and s.granularity == "day",
          group_by: [s.provider, s.period_start],
          order_by: s.period_start,
          select: %{
            day: s.period_start,
            provider: s.provider,
            amount_cents: coalesce(sum(s.amount_cents), 0)
          }
      )

    credits_by_day =
      Repo.all(
        from t in CreditTransaction,
          where: t.inserted_at >= ^since and t.kind == "spend",
          group_by: fragment("date_trunc('day', ?)", t.inserted_at),
          order_by: fragment("date_trunc('day', ?)", t.inserted_at),
          select: %{
            day: fragment("date_trunc('day', ?)", t.inserted_at),
            credits: coalesce(sum(fragment("abs(?)", t.amount)), 0),
            cost_cents: coalesce(sum(t.cost_cents), 0)
          }
      )

    %{
      days: days,
      new_users: users_by_day,
      usage: usage_by_day,
      provider_costs: provider_by_day,
      credits_spend: credits_by_day
    }
  end

  defp cost_mtd_by_provider(month_start) do
    Repo.all(
      from s in Mokaid.Billing.PlatformCostSnapshot,
        where: s.period_start >= ^month_start and s.granularity == "day",
        group_by: s.provider,
        select: {s.provider, coalesce(sum(s.amount_cents), 0)}
    )
    |> Map.new()
  end

  # ---------- Users ----------

  def list_users(opts \\ %{}) do
    page = parse_int(opts["page"], 1)
    per_page = min(parse_int(opts["per_page"], 25), 100)
    offset = (page - 1) * per_page
    q = Map.get(opts, "q") || Map.get(opts, "search")
    status = Map.get(opts, "status")

    base =
      from u in User,
        order_by: [desc: u.inserted_at]

    base =
      if is_binary(q) and String.trim(q) != "" do
        like = "%#{String.downcase(String.trim(q))}%"

        from u in base,
          where:
            fragment("lower(?) LIKE ?", u.email, ^like) or
              fragment("lower(?) LIKE ?", u.full_name, ^like)
      else
        base
      end

    base =
      if is_binary(status) and status != "" and status != "all" do
        from u in base, where: u.status == ^status
      else
        base
      end

    total = Repo.aggregate(base, :count)

    users =
      Repo.all(from u in base, limit: ^per_page, offset: ^offset)
      |> Repo.preload(memberships: [:workspace, :role])

    %{data: users, page: page, per_page: per_page, total: total}
  end

  def get_user(id) do
    case Accounts.get_user(id) do
      nil -> nil
      user -> Repo.preload(user, memberships: [:workspace, :role])
    end
  end

  def update_user(%User{} = user, attrs, actor) do
    allowed =
      Map.take(attrs, [
        "full_name",
        "locale",
        "timezone",
        "status",
        "is_platform_admin",
        "operator_notes"
      ])

    with {:ok, allowed} <- guard_platform_admin_change(user, allowed, actor),
         cs <- admin_user_changeset(user, allowed),
         {:ok, updated} <- Repo.update(cs) do
      audit(actor, nil, "admin.user.update", "user", updated.id, %{
        changes: Map.keys(allowed)
      })

      {:ok, Repo.preload(updated, memberships: [:workspace, :role])}
    end
  end

  def reset_user_password(%User{} = user, password, actor)
      when is_binary(password) and byte_size(password) >= 10 do
    hashed = Bcrypt.hash_pwd_salt(password)

    case user
         |> Ecto.Changeset.change(hashed_password: hashed)
         |> Repo.update() do
      {:ok, updated} ->
        audit(actor, nil, "admin.user.reset_password", "user", updated.id, %{})
        {:ok, updated}

      error ->
        error
    end
  end

  def reset_user_password(_user, _password, _actor), do: {:error, :invalid_password}

  @deletion_grace_days 30

  def ban_user(%User{} = user, actor, opts \\ %{}) do
    with :ok <- guard_self_target(user, actor),
         :ok <- guard_last_admin_ban(user) do
      reason = Map.get(opts, "reason") || Map.get(opts, :reason) || "Banned by operator"
      expires = parse_datetime(Map.get(opts, "ban_expires_at") || Map.get(opts, :ban_expires_at))

      attrs = %{
        status: "suspended",
        banned_at: DateTime.utc_now(),
        banned_by_id: actor.id,
        ban_reason: reason,
        ban_expires_at: expires
      }

      case user |> User.moderation_changeset(attrs) |> Repo.update() do
        {:ok, updated} ->
          platform_audit(actor, "admin.user.ban", "user", updated.id, nil, %{
            reason: reason,
            ban_expires_at: expires
          }, opts)

          {:ok, Repo.preload(updated, memberships: [:workspace, :role])}

        error ->
          error
      end
    end
  end

  def unban_user(%User{} = user, actor, opts \\ %{}) do
    attrs = %{
      status: "active",
      banned_at: nil,
      banned_by_id: nil,
      ban_reason: nil,
      ban_expires_at: nil
    }

    case user |> User.moderation_changeset(attrs) |> Repo.update() do
      {:ok, updated} ->
        platform_audit(actor, "admin.user.unban", "user", updated.id, nil, %{}, opts)
        {:ok, Repo.preload(updated, memberships: [:workspace, :role])}

      error ->
        error
    end
  end

  def schedule_user_deletion(%User{} = user, actor, opts \\ %{}) do
    with :ok <- guard_self_target(user, actor),
         :ok <- guard_last_admin_ban(user) do
      reason = Map.get(opts, "reason") || "Scheduled by operator"
      days = parse_int(Map.get(opts, "days"), @deletion_grace_days)
      scheduled = DateTime.add(DateTime.utc_now(), days * 24 * 3600, :second)

      attrs = %{
        status: "suspended",
        deletion_scheduled_at: scheduled,
        ban_reason: reason,
        banned_at: user.banned_at || DateTime.utc_now(),
        banned_by_id: actor.id
      }

      case user |> User.moderation_changeset(attrs) |> Repo.update() do
        {:ok, updated} ->
          platform_audit(actor, "admin.user.schedule_deletion", "user", updated.id, nil, %{
            deletion_scheduled_at: scheduled,
            reason: reason,
            grace_days: days
          }, opts)

          {:ok, Repo.preload(updated, memberships: [:workspace, :role])}

        error ->
          error
      end
    end
  end

  def cancel_user_deletion(%User{} = user, actor, opts \\ %{}) do
    attrs = %{
      deletion_scheduled_at: nil,
      status: if(is_nil(user.banned_at), do: "active", else: user.status)
    }

    case user |> User.moderation_changeset(attrs) |> Repo.update() do
      {:ok, updated} ->
        platform_audit(actor, "admin.user.cancel_deletion", "user", updated.id, nil, %{}, opts)
        {:ok, Repo.preload(updated, memberships: [:workspace, :role])}

      error ->
        error
    end
  end

  def user_summary(id) do
    case get_user(id) do
      nil ->
        nil

      user ->
        workspace_ids =
          Enum.map(user.memberships || [], & &1.workspace_id) |> Enum.reject(&is_nil/1)

        logins =
          Repo.all(
            from e in Mokaid.Accounts.UserLoginEvent,
              where: e.user_id == ^user.id,
              order_by: [desc: e.occurred_at],
              limit: 20
          )

        credit_txns =
          if workspace_ids == [] do
            []
          else
            Repo.all(
              from t in CreditTransaction,
                where: t.workspace_id in ^workspace_ids,
                order_by: [desc: t.inserted_at],
                limit: 30
            )
          end

        usage =
          if workspace_ids == [] do
            []
          else
            Repo.all(
              from e in UsageEvent,
                where: e.workspace_id in ^workspace_ids,
                order_by: [desc: e.occurred_at],
                limit: 30
            )
          end

        invoices =
          if workspace_ids == [] do
            []
          else
            Repo.all(
              from i in Invoice,
                where: i.workspace_id in ^workspace_ids,
                order_by: [desc: i.issued_at],
                limit: 20,
                preload: [:workspace]
            )
          end

        subscriptions =
          if workspace_ids == [] do
            []
          else
            Repo.all(
              from s in Subscription,
                where: s.workspace_id in ^workspace_ids,
                preload: [:plan, :workspace]
            )
          end

        usage_cost_30d =
          if workspace_ids == [] do
            0
          else
            since = DateTime.add(DateTime.utc_now(), -30, :day)

            Repo.one(
              from e in UsageEvent,
                where: e.workspace_id in ^workspace_ids and e.occurred_at >= ^since,
                select: coalesce(sum(e.cost_cents), 0)
            ) || 0
          end

        audit_logs =
          Repo.all(
            from l in AuditLog,
              where: l.resource_type == "user" and l.resource_id == ^user.id,
              order_by: [desc: l.occurred_at],
              limit: 30
          )

        %{
          user: user,
          logins: logins,
          credit_transactions: credit_txns,
          usage_events: usage,
          invoices: invoices,
          subscriptions: subscriptions,
          usage_cost_30d_cents: usage_cost_30d,
          audit_logs: audit_logs
        }
    end
  end

  defp guard_self_target(%User{id: id}, %User{id: id}), do: {:error, :cannot_target_self}
  defp guard_self_target(_, _), do: :ok

  defp guard_last_admin_ban(%User{is_platform_admin: true} = user) do
    admins =
      Repo.one(from u in User, where: u.is_platform_admin == true, select: count(u.id)) || 0

    if admins <= 1 and user.is_platform_admin, do: {:error, :last_platform_admin}, else: :ok
  end

  defp guard_last_admin_ban(_), do: :ok

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp guard_platform_admin_change(
         %User{id: id} = user,
         %{"is_platform_admin" => false} = attrs,
         %{
           id: id
         }
       ) do
    _ = user
    _ = attrs
    {:error, :cannot_demote_self}
  end

  defp guard_platform_admin_change(
         %User{} = user,
         %{"is_platform_admin" => false} = attrs,
         _actor
       ) do
    admins =
      Repo.one(from u in User, where: u.is_platform_admin == true, select: count(u.id)) || 0

    if admins <= 1 and user.is_platform_admin do
      {:error, :last_platform_admin}
    else
      {:ok, attrs}
    end
  end

  defp guard_platform_admin_change(_user, attrs, _actor), do: {:ok, attrs}

  defp admin_user_changeset(user, attrs) do
    user
    |> Ecto.Changeset.cast(attrs, [
      :full_name,
      :locale,
      :timezone,
      :status,
      :is_platform_admin,
      :operator_notes
    ])
    |> Ecto.Changeset.validate_inclusion(:status, ~w(active suspended disabled))
    |> Ecto.Changeset.validate_inclusion(:locale, ~w(en fr he))
  end

  # ---------- Workspaces ----------

  def list_workspaces(opts \\ %{}) do
    page = parse_int(opts["page"], 1)
    per_page = min(parse_int(opts["per_page"], 25), 100)
    offset = (page - 1) * per_page
    q = Map.get(opts, "q") || Map.get(opts, "search")
    include_deleted = opts["include_deleted"] in [true, "true", "1"]

    base =
      from w in Workspace,
        order_by: [desc: w.inserted_at]

    base =
      if include_deleted do
        base
      else
        from w in base, where: is_nil(w.deleted_at)
      end

    base =
      if is_binary(q) and String.trim(q) != "" do
        like = "%#{String.downcase(String.trim(q))}%"

        from w in base,
          where:
            fragment("lower(?) LIKE ?", w.name, ^like) or
              fragment("lower(?) LIKE ?", w.slug, ^like)
      else
        base
      end

    total = Repo.aggregate(base, :count)

    workspaces = Repo.all(from w in base, limit: ^per_page, offset: ^offset)

    member_counts =
      workspaces
      |> Enum.map(& &1.id)
      |> then(fn ids ->
        if ids == [] do
          %{}
        else
          Repo.all(
            from m in Member,
              where: m.workspace_id in ^ids and m.status == "active",
              group_by: m.workspace_id,
              select: {m.workspace_id, count(m.id)}
          )
          |> Map.new()
        end
      end)

    subs =
      workspaces
      |> Enum.map(& &1.id)
      |> then(fn ids ->
        if ids == [] do
          %{}
        else
          Repo.all(
            from s in Subscription,
              where: s.workspace_id in ^ids,
              preload: [:plan]
          )
          |> Map.new(&{&1.workspace_id, &1})
        end
      end)

    data =
      Enum.map(workspaces, fn w ->
        %{
          workspace: w,
          member_count: Map.get(member_counts, w.id, 0),
          subscription: Map.get(subs, w.id)
        }
      end)

    %{data: data, page: page, per_page: per_page, total: total}
  end

  def get_workspace(id) do
    case Workspaces.get_workspace(id) do
      nil ->
        nil

      workspace ->
        sub = Billing.get_subscription(id)
        members = Members.list_members(id)
        %{workspace: workspace, subscription: sub, members: members}
    end
  end

  def update_workspace(%Workspace{} = workspace, attrs, actor) do
    allowed =
      Map.take(attrs, [
        "name",
        "description",
        "industry",
        "timezone",
        "language",
        "feature_toggles",
        "usage_limits",
        "settings",
        "default_landing_page"
      ])

    cs =
      workspace
      |> Workspace.changeset(allowed)
      |> maybe_put_usage_limits(allowed)

    with {:ok, updated} <- Repo.update(cs) do
      audit(actor, workspace.id, "admin.workspace.update", "workspace", updated.id, %{
        changes: Map.keys(allowed)
      })

      {:ok, updated}
    end
  end

  def soft_delete_workspace(%Workspace{} = workspace, actor) do
    with {:ok, updated} <- Workspaces.soft_delete_workspace(workspace) do
      audit(actor, workspace.id, "admin.workspace.delete", "workspace", updated.id, %{})
      {:ok, updated}
    end
  end

  def restore_workspace(%Workspace{} = workspace, actor) do
    with {:ok, updated} <-
           workspace |> Ecto.Changeset.change(deleted_at: nil) |> Repo.update() do
      audit(actor, workspace.id, "admin.workspace.restore", "workspace", updated.id, %{})
      {:ok, updated}
    end
  end

  defp maybe_put_usage_limits(cs, %{"usage_limits" => limits}) when is_map(limits) do
    Ecto.Changeset.put_change(cs, :usage_limits, limits)
  end

  defp maybe_put_usage_limits(cs, _), do: cs

  # ---------- Plans ----------

  def list_plans, do: Billing.list_plans()

  def get_plan(id), do: Repo.get(BillingPlan, id)

  def create_plan(attrs, actor) do
    with {:ok, plan} <- %BillingPlan{} |> BillingPlan.changeset(attrs) |> Repo.insert() do
      audit(actor, nil, "admin.plan.create", "billing_plan", plan.id, %{key: plan.key})
      {:ok, plan}
    end
  end

  def update_plan(%BillingPlan{} = plan, attrs, actor) do
    with {:ok, updated} <- plan |> BillingPlan.changeset(attrs) |> Repo.update() do
      audit(actor, nil, "admin.plan.update", "billing_plan", updated.id, %{key: updated.key})
      {:ok, updated}
    end
  end

  # ---------- Subscriptions ----------

  def list_subscriptions(opts \\ %{}) do
    page = parse_int(opts["page"], 1)
    per_page = min(parse_int(opts["per_page"], 25), 100)
    offset = (page - 1) * per_page
    status = Map.get(opts, "status")
    plan_key = Map.get(opts, "plan_key")

    base =
      from s in Subscription,
        join: w in assoc(s, :workspace),
        join: p in assoc(s, :plan),
        preload: [:plan, :workspace],
        order_by: [desc: s.updated_at]

    base =
      if is_binary(status) and status != "" and status != "all" do
        from [s, w, p] in base, where: s.status == ^status
      else
        base
      end

    base =
      if is_binary(plan_key) and plan_key != "" and plan_key != "all" do
        from [s, w, p] in base, where: p.key == ^plan_key
      else
        base
      end

    total =
      base
      |> exclude(:preload)
      |> exclude(:order_by)
      |> select([s, w, p], count(s.id))
      |> Repo.one() || 0

    data = Repo.all(from s in base, limit: ^per_page, offset: ^offset)

    %{data: data, page: page, per_page: per_page, total: total}
  end

  def get_subscription(id) do
    Repo.one(
      from s in Subscription,
        where: s.id == ^id,
        preload: [:plan, :workspace]
    )
  end

  def update_subscription(%Subscription{} = sub, attrs, actor) do
    plan_key = attrs["plan_key"]
    billing_cycle = attrs["billing_cycle"]
    status = attrs["status"]
    credits = attrs["credits_adjustment"]

    result =
      Repo.transaction(fn ->
        sub = Repo.preload(sub, :plan)

        sub =
          if is_binary(plan_key) and plan_key != "" do
            case Billing.change_plan(sub.workspace_id, plan_key, billing_cycle) do
              {:ok, updated} -> updated
              {:error, reason} -> Repo.rollback(reason)
            end
          else
            sub
          end

        sub =
          if is_binary(status) and status in ~w(active past_due canceled canceled_at_period_end) do
            case sub |> Ecto.Changeset.change(status: status) |> Repo.update() do
              {:ok, updated} -> updated
              {:error, cs} -> Repo.rollback(cs)
            end
          else
            sub
          end

        if is_integer(credits) and credits != 0 do
          case adjust_credits(sub.workspace_id, credits, actor, audit?: false) do
            {:ok, _} -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end
        end

        get_subscription(sub.id) || sub
      end)

    case result do
      {:ok, updated} ->
        audit(actor, sub.workspace_id, "admin.subscription.update", "subscription", sub.id, %{
          attrs: Map.take(attrs, ["plan_key", "billing_cycle", "status", "credits_adjustment"])
        })

        {:ok, updated}

      error ->
        error
    end
  end

  # ---------- Invoices ----------

  def list_invoices(opts \\ %{}) do
    page = parse_int(opts["page"], 1)
    per_page = min(parse_int(opts["per_page"], 25), 100)
    offset = (page - 1) * per_page
    status = Map.get(opts, "status")
    workspace_id = Map.get(opts, "workspace_id")

    base = from i in Invoice, preload: [:workspace], order_by: [desc: i.issued_at]

    base =
      if is_binary(status) and status != "" and status != "all" do
        from i in base, where: i.status == ^status
      else
        base
      end

    base =
      if is_binary(workspace_id) and workspace_id != "" do
        from i in base, where: i.workspace_id == ^workspace_id
      else
        base
      end

    total = Repo.aggregate(base, :count)
    data = Repo.all(from i in base, limit: ^per_page, offset: ^offset)
    %{data: data, page: page, per_page: per_page, total: total}
  end

  def get_invoice(id),
    do: Repo.get(Invoice, id) |> then(&if(&1, do: Repo.preload(&1, :workspace)))

  def mark_invoice_paid(%Invoice{} = invoice, actor) do
    with {:ok, paid} <- Billing.mark_invoice_paid(invoice, nil) do
      audit(actor, invoice.workspace_id, "admin.invoice.mark_paid", "invoice", paid.id, %{})
      {:ok, Repo.preload(paid, :workspace)}
    end
  end

  def void_invoice(%Invoice{} = invoice, actor) do
    if invoice.status in ["paid", "void"] do
      {:error, :invalid_status}
    else
      case invoice
           |> Ecto.Changeset.change(status: "void")
           |> Repo.update() do
        {:ok, updated} ->
          audit(actor, invoice.workspace_id, "admin.invoice.void", "invoice", updated.id, %{})
          {:ok, Repo.preload(updated, :workspace)}

        error ->
          error
      end
    end
  end

  # ---------- Credits ----------

  def list_credit_transactions(opts \\ %{}) do
    page = parse_int(opts["page"], 1)
    per_page = min(parse_int(opts["per_page"], 25), 100)
    offset = (page - 1) * per_page
    workspace_id = Map.get(opts, "workspace_id")

    base = from t in CreditTransaction, order_by: [desc: t.inserted_at]

    base =
      if is_binary(workspace_id) and workspace_id != "" do
        from t in base, where: t.workspace_id == ^workspace_id
      else
        base
      end

    total = Repo.aggregate(base, :count)
    data = Repo.all(from t in base, limit: ^per_page, offset: ^offset)
    %{data: data, page: page, per_page: per_page, total: total}
  end

  def list_usage_events(opts \\ %{}) do
    page = parse_int(opts["page"], 1)
    per_page = min(parse_int(opts["per_page"], 25), 100)
    offset = (page - 1) * per_page
    workspace_id = Map.get(opts, "workspace_id")

    base = from e in UsageEvent, order_by: [desc: e.occurred_at]

    base =
      if is_binary(workspace_id) and workspace_id != "" do
        from e in base, where: e.workspace_id == ^workspace_id
      else
        base
      end

    total = Repo.aggregate(base, :count)
    data = Repo.all(from e in base, limit: ^per_page, offset: ^offset)
    %{data: data, page: page, per_page: per_page, total: total}
  end

  def adjust_credits(workspace_id, amount, actor, opts \\ [])
      when is_integer(amount) and amount != 0 do
    audit? = Keyword.get(opts, :audit?, true)
    reason = Keyword.get(opts, :reason) || Keyword.get(opts, :description)
    idempotency_key = Keyword.get(opts, :idempotency_key)

    case Billing.Credits.admin_adjust(workspace_id, amount,
           reason: reason,
           operator_id: actor && actor.id,
           idempotency_key: idempotency_key
         ) do
      {:ok, sub, _txn, status} ->
        if audit? do
          audit(actor, workspace_id, "admin.credits.adjust", "subscription", sub.id, %{
            amount: amount,
            reason: reason,
            status: status
          })
        end

        {:ok, sub}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # force_debit_credits removed — admin_adjust is authoritative

  # ---------- Costs ----------

  def list_costs(opts \\ %{}) do
    days = min(parse_int(Map.get(opts, "days"), 30), 90)
    provider = Map.get(opts, "provider")
    since = DateTime.add(DateTime.utc_now(), -days, :day)

    base =
      from s in Mokaid.Billing.PlatformCostSnapshot,
        where: s.period_start >= ^since,
        order_by: [desc: s.period_start]

    base =
      if is_binary(provider) and provider != "" and provider != "all" do
        from s in base, where: s.provider == ^provider
      else
        base
      end

    rows = Repo.all(base)

    totals =
      rows
      |> Enum.group_by(& &1.provider)
      |> Enum.map(fn {p, list} -> {p, Enum.reduce(list, 0, &(&1.amount_cents + &2))} end)
      |> Map.new()

    reconciliation =
      Repo.all(
        from r in Mokaid.Billing.CostReconciliationDaily,
          where: r.day >= ^Date.add(Date.utc_today(), -days),
          order_by: [desc: r.day]
      )

    %{
      days: days,
      snapshots: rows,
      totals_cents: totals,
      total_cents: Enum.reduce(Map.values(totals), 0, &+/2),
      reconciliation: reconciliation
    }
  end

  def cost_summary(opts \\ %{}) do
    data = list_costs(opts)
    m = metrics()

    %{
      mrr_cents: m.mrr_cents,
      internal_ai_cost_mtd_cents: m.internal_ai_cost_mtd_cents,
      provider_cost_mtd_cents: m.provider_cost_mtd_cents,
      openai_cost_mtd_cents: m.openai_cost_mtd_cents,
      anthropic_cost_mtd_cents: m.anthropic_cost_mtd_cents,
      aws_cost_mtd_cents: m.aws_cost_mtd_cents,
      gross_margin_cents: m.gross_margin_cents,
      window_totals_cents: data.totals_cents,
      window_total_cents: data.total_cents,
      days: data.days,
      reconciliation: data.reconciliation
    }
  end

  # ---------- Unified logs ----------

  def list_unified_logs(opts \\ %{}) do
    page = parse_int(opts["page"], 1)
    per_page = min(parse_int(opts["per_page"], 50), 200)
    source = Map.get(opts, "source") || "all"
    q = Map.get(opts, "q")

    audit =
      if source in ["all", "audit"] do
        list_audit_logs(Map.merge(opts, %{"per_page" => per_page, "page" => 1})).data
        |> Enum.map(fn l ->
          %{
            id: l.id,
            source: "audit",
            occurred_at: l.occurred_at,
            actor: l.actor_name || l.actor_type,
            action: l.action,
            resource_type: l.resource_type,
            resource_id: l.resource_id,
            workspace_id: l.workspace_id,
            message: l.action,
            metadata: redact_map(l.metadata || %{})
          }
        end)
      else
        []
      end

    platform =
      if source in ["all", "platform_audit"] do
        Repo.all(
          from e in Mokaid.Audit.PlatformAuditEvent,
            order_by: [desc: e.occurred_at],
            limit: ^per_page
        )
        |> Enum.map(fn e ->
          %{
            id: e.id,
            source: "platform_audit",
            occurred_at: e.occurred_at,
            actor: e.actor_name || e.actor_email,
            action: e.action,
            resource_type: e.resource_type,
            resource_id: e.resource_id,
            workspace_id: e.workspace_id,
            message: e.action,
            ip_address: e.ip_address,
            metadata: redact_map(e.metadata || %{})
          }
        end)
      else
        []
      end

    logins =
      if source in ["all", "logins"] do
        Repo.all(
          from e in Mokaid.Accounts.UserLoginEvent,
            order_by: [desc: e.occurred_at],
            limit: ^per_page,
            preload: [:user]
        )
        |> Enum.map(fn e ->
          %{
            id: e.id,
            source: "login",
            occurred_at: e.occurred_at,
            actor: e.user && (e.user.email || e.user.full_name),
            action: if(e.success, do: "login.success", else: "login.failure"),
            resource_type: "user",
            resource_id: e.user_id,
            message: "auth=#{e.auth_method}",
            ip_address: e.ip_address,
            metadata: redact_map(%{"user_agent" => e.user_agent})
          }
        end)
      else
        []
      end

    cloudwatch =
      if source in ["all", "cloudwatch"] do
        Mokaid.Observability.CloudWatchLogs.filter(opts)
      else
        []
      end

    events =
      (audit ++ platform ++ logins ++ cloudwatch)
      |> Enum.sort_by(& &1.occurred_at, {:desc, DateTime})
      |> then(fn list ->
        if is_binary(q) and String.trim(q) != "" do
          ql = String.downcase(q)

          Enum.filter(list, fn e ->
            String.contains?(String.downcase(to_string(e[:message] || "")), ql) or
              String.contains?(String.downcase(to_string(e[:action] || "")), ql) or
              String.contains?(String.downcase(to_string(e[:actor] || "")), ql)
          end)
        else
          list
        end
      end)

    total = length(events)
    offset = (page - 1) * per_page
    data = Enum.slice(events, offset, per_page)
    %{data: data, page: page, per_page: per_page, total: total}
  end

  defp redact_map(map) when is_map(map) do
    sensitive = ~w(password token secret authorization api_key access_token refresh_token)

    Enum.reduce(map, %{}, fn {k, v}, acc ->
      key = to_string(k)

      if Enum.any?(sensitive, &String.contains?(String.downcase(key), &1)) do
        Map.put(acc, k, "[REDACTED]")
      else
        Map.put(acc, k, v)
      end
    end)
  end

  defp redact_map(other), do: other

  # ---------- Audit ----------

  def list_audit_logs(opts \\ %{}) do
    page = parse_int(opts["page"], 1)
    per_page = min(parse_int(opts["per_page"], 50), 200)
    offset = (page - 1) * per_page
    workspace_id = Map.get(opts, "workspace_id")
    action = Map.get(opts, "action")
    resource_type = Map.get(opts, "resource_type")
    actor_type = Map.get(opts, "actor_type")

    base = from l in AuditLog, order_by: [desc: l.occurred_at]

    base =
      if is_binary(workspace_id) and workspace_id != "" do
        from l in base, where: l.workspace_id == ^workspace_id
      else
        base
      end

    base =
      if is_binary(action) and action != "" do
        like = "%#{action}%"
        from l in base, where: ilike(l.action, ^like)
      else
        base
      end

    base =
      if is_binary(resource_type) and resource_type != "" do
        from l in base, where: l.resource_type == ^resource_type
      else
        base
      end

    base =
      if is_binary(actor_type) and actor_type != "" do
        from l in base, where: l.actor_type == ^actor_type
      else
        base
      end

    total = Repo.aggregate(base, :count)
    data = Repo.all(from l in base, limit: ^per_page, offset: ^offset)
    %{data: data, page: page, per_page: per_page, total: total}
  end

  # ---------- Members ----------

  def list_members(opts \\ %{}) do
    page = parse_int(opts["page"], 1)
    per_page = min(parse_int(opts["per_page"], 25), 100)
    offset = (page - 1) * per_page
    workspace_id = Map.get(opts, "workspace_id")
    status = Map.get(opts, "status")

    base =
      from m in Member,
        preload: [:user, :role, :workspace],
        order_by: [desc: m.inserted_at]

    base =
      if is_binary(workspace_id) and workspace_id != "" do
        from m in base, where: m.workspace_id == ^workspace_id
      else
        base
      end

    base =
      if is_binary(status) and status != "" and status != "all" do
        from m in base, where: m.status == ^status
      else
        base
      end

    total = Repo.aggregate(base, :count)
    data = Repo.all(from m in base, limit: ^per_page, offset: ^offset)
    %{data: data, page: page, per_page: per_page, total: total}
  end

  def update_member(%Member{} = member, attrs, actor) do
    role_name = attrs["role_name"]
    status = attrs["status"]

    updates = %{}

    updates =
      if is_binary(role_name) and role_name != "" do
        case Members.get_role_by_name(member.workspace_id, role_name) do
          %Role{id: rid} -> Map.put(updates, "role_id", rid)
          nil -> updates
        end
      else
        updates
      end

    updates =
      if is_binary(status) and status != "" do
        Map.put(updates, "status", status)
      else
        updates
      end

    with {:ok, updated} <- Members.update_member(member, updates) do
      audit(actor, member.workspace_id, "admin.member.update", "member", updated.id, %{
        changes: Map.keys(updates)
      })

      {:ok, Repo.preload(updated, [:user, :role, :workspace], force: true)}
    end
  end

  def list_invites(opts \\ %{}) do
    page = parse_int(opts["page"], 1)
    per_page = min(parse_int(opts["per_page"], 25), 100)
    offset = (page - 1) * per_page
    workspace_id = Map.get(opts, "workspace_id")

    base =
      from i in MemberInvite,
        preload: [:role, :workspace],
        order_by: [desc: i.inserted_at]

    base =
      if is_binary(workspace_id) and workspace_id != "" do
        from i in base, where: i.workspace_id == ^workspace_id
      else
        base
      end

    total = Repo.aggregate(base, :count)
    data = Repo.all(from i in base, limit: ^per_page, offset: ^offset)
    %{data: data, page: page, per_page: per_page, total: total}
  end

  def cancel_invite(%MemberInvite{} = invite, actor) do
    with {:ok, updated} <-
           invite |> Ecto.Changeset.change(status: "cancelled") |> Repo.update() do
      audit(actor, invite.workspace_id, "admin.invite.cancel", "member_invite", updated.id, %{})
      {:ok, updated}
    end
  end

  # ---------- Helpers ----------

  defp audit(%User{} = actor, workspace_id, action, resource_type, resource_id, metadata) do
    platform_audit(actor, action, resource_type, resource_id, workspace_id, metadata, %{})

    %AuditLog{}
    |> AuditLog.changeset(%{
      "workspace_id" => workspace_id,
      "actor_type" => "platform_admin",
      "actor_id" => actor.id,
      "actor_name" => actor.full_name || actor.email,
      "action" => action,
      "resource_type" => resource_type,
      "resource_id" => resource_id,
      "metadata" => metadata || %{}
    })
    |> Repo.insert()

    :ok
  end

  defp platform_audit(actor, action, resource_type, resource_id, workspace_id, metadata, opts) do
    ip = Map.get(opts, :ip) || Map.get(opts, "ip")
    ua = Map.get(opts, :user_agent) || Map.get(opts, "user_agent")

    %Mokaid.Audit.PlatformAuditEvent{}
    |> Mokaid.Audit.PlatformAuditEvent.changeset(%{
      actor_id: actor && actor.id,
      actor_email: actor && actor.email,
      actor_name: actor && (actor.full_name || actor.email),
      action: action,
      resource_type: resource_type,
      resource_id: resource_id,
      workspace_id: workspace_id,
      ip_address: ip && to_string(ip),
      user_agent: ua && to_string(ua) |> String.slice(0, 500),
      metadata: metadata || %{},
      occurred_at: DateTime.utc_now()
    })
    |> Repo.insert()

    :ok
  rescue
    e ->
      require Logger
      Logger.warning("platform_audit insert failed: #{inspect(e)}")
      :ok
  end

  defp parse_int(nil, default), do: default
  defp parse_int(v, _default) when is_integer(v) and v > 0, do: v

  defp parse_int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_int(_, default), do: default
end
