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

    users_total = Repo.aggregate(User, :count)
    users_active = Repo.one(from u in User, where: u.status == "active", select: count(u.id))

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

    %{
      users_total: users_total,
      users_active: users_active || 0,
      workspaces_total: workspaces_total || 0,
      mrr_cents: mrr_cents,
      subscriptions_active: subs_active,
      subscriptions_past_due: subs_past_due,
      invoices_pending: invoices_pending || 0,
      new_users_30d: new_users_30d || 0
    }
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
        "is_platform_admin"
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
      :is_platform_admin
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

    cond do
      amount > 0 ->
        case Billing.Credits.add_purchased(workspace_id, amount,
               kind: "adjustment",
               description: "Platform admin credit adjustment"
             ) do
          {:ok, sub} = ok ->
            if audit?,
              do:
                audit(actor, workspace_id, "admin.credits.adjust", "subscription", sub.id, %{
                  amount: amount
                })

            ok

          _err ->
            # Ensure sub exists for free workspaces
            _ = Billing.change_plan(workspace_id, "free")

            case Billing.Credits.add_purchased(workspace_id, amount,
                   kind: "adjustment",
                   description: "Platform admin credit adjustment"
                 ) do
              {:ok, sub} = ok ->
                if audit?,
                  do:
                    audit(actor, workspace_id, "admin.credits.adjust", "subscription", sub.id, %{
                      amount: amount
                    })

                ok

              err2 ->
                err2
            end
        end

      amount < 0 ->
        case force_debit_credits(workspace_id, -amount) do
          {:ok, sub} = ok ->
            if audit?,
              do:
                audit(actor, workspace_id, "admin.credits.adjust", "subscription", sub.id, %{
                  amount: amount
                })

            ok

          error ->
            error
        end
    end
  end

  defp force_debit_credits(workspace_id, credits) when credits > 0 do
    case Billing.get_subscription(workspace_id) do
      nil ->
        {:error, :no_subscription}

      sub ->
        from_included = min(sub.included_credits_remaining || 0, credits)
        from_balance = credits - from_included

        {1, [updated]} =
          Repo.update_all(
            from(s in Subscription, where: s.id == ^sub.id, select: s),
            inc: [
              included_credits_remaining: -from_included,
              credits_balance: -from_balance
            ]
          )

        %CreditTransaction{}
        |> CreditTransaction.changeset(%{
          "workspace_id" => workspace_id,
          "kind" => "adjustment",
          "amount" => -credits,
          "balance_after" =>
            (updated.included_credits_remaining || 0) + (updated.credits_balance || 0),
          "description" => "Platform admin credit adjustment"
        })
        |> Repo.insert()

        {:ok, updated}
    end
  end

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
