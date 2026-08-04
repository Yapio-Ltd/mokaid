defmodule MokaidWeb.AdminController do
  use MokaidWeb, :controller

  alias Mokaid.Admin
  alias MokaidWeb.JSON, as: Serializer

  # ---------- Dashboard ----------

  def metrics(conn, _params) do
    json(conn, %{data: Admin.metrics()})
  end

  # ---------- Users ----------

  def list_users(conn, params) do
    result = Admin.list_users(params)

    json(conn, %{
      data: Enum.map(result.data, &admin_user/1),
      meta: page_meta(result)
    })
  end

  def show_user(conn, %{"id" => id}) do
    case Admin.get_user(id) do
      nil -> {:error, :not_found}
      user -> json(conn, %{data: admin_user(user)})
    end
  end

  def update_user(conn, %{"id" => id} = params) do
    actor = current_user(conn)

    with %{} = user <- Admin.get_user(id),
         {:ok, updated} <- Admin.update_user(user, params, actor) do
      json(conn, %{data: admin_user(updated)})
    end
  end

  def reset_password(conn, %{"id" => id, "password" => password}) do
    actor = current_user(conn)

    with %{} = user <- Admin.get_user(id),
         {:ok, _updated} <- Admin.reset_user_password(user, password, actor) do
      json(conn, %{ok: true})
    end
  end

  def reset_password(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{code: "bad_request", message: "password is required"}})
  end

  # ---------- Workspaces ----------

  def list_workspaces(conn, params) do
    result = Admin.list_workspaces(params)

    json(conn, %{
      data:
        Enum.map(result.data, fn row ->
          Serializer.workspace(row.workspace)
          |> Map.merge(%{
            deleted_at: row.workspace.deleted_at,
            usage_limits: row.workspace.usage_limits,
            member_count: row.member_count,
            subscription: subscription_json(row.subscription)
          })
        end),
      meta: page_meta(result)
    })
  end

  def show_workspace(conn, %{"id" => id}) do
    case Admin.get_workspace(id) do
      nil ->
        {:error, :not_found}

      %{workspace: w, subscription: sub, members: members} ->
        json(conn, %{
          data:
            Serializer.workspace(w)
            |> Map.merge(%{
              deleted_at: w.deleted_at,
              usage_limits: w.usage_limits,
              subscription: subscription_json(sub),
              members: Enum.map(members, &Serializer.member/1)
            })
        })
    end
  end

  def update_workspace(conn, %{"id" => id} = params) do
    actor = current_user(conn)

    with %{} = w <- Mokaid.Workspaces.get_workspace(id),
         {:ok, updated} <- Admin.update_workspace(w, params, actor) do
      json(conn, %{
        data:
          Serializer.workspace(updated)
          |> Map.put(:usage_limits, updated.usage_limits)
          |> Map.put(:deleted_at, updated.deleted_at)
      })
    end
  end

  def delete_workspace(conn, %{"id" => id}) do
    actor = current_user(conn)

    with %{} = w <- Mokaid.Workspaces.get_workspace(id),
         {:ok, updated} <- Admin.soft_delete_workspace(w, actor) do
      json(conn, %{data: %{id: updated.id, deleted_at: updated.deleted_at}})
    end
  end

  def restore_workspace(conn, %{"id" => id}) do
    actor = current_user(conn)

    with %{} = w <- Mokaid.Workspaces.get_workspace(id),
         {:ok, updated} <- Admin.restore_workspace(w, actor) do
      json(conn, %{data: Serializer.workspace(updated)})
    end
  end

  # ---------- Plans ----------

  def list_plans(conn, _params) do
    json(conn, %{data: Enum.map(Admin.list_plans(), &plan_json/1)})
  end

  def create_plan(conn, params) do
    with {:ok, plan} <- Admin.create_plan(params, current_user(conn)) do
      conn
      |> put_status(:created)
      |> json(%{data: plan_json(plan)})
    end
  end

  def update_plan(conn, %{"id" => id} = params) do
    with %{} = plan <- Admin.get_plan(id),
         {:ok, updated} <- Admin.update_plan(plan, params, current_user(conn)) do
      json(conn, %{data: plan_json(updated)})
    end
  end

  # ---------- Subscriptions ----------

  def list_subscriptions(conn, params) do
    result = Admin.list_subscriptions(params)

    json(conn, %{
      data: Enum.map(result.data, &subscription_json/1),
      meta: page_meta(result)
    })
  end

  def show_subscription(conn, %{"id" => id}) do
    case Admin.get_subscription(id) do
      nil -> {:error, :not_found}
      sub -> json(conn, %{data: subscription_json(sub)})
    end
  end

  def update_subscription(conn, %{"id" => id} = params) do
    actor = current_user(conn)

    attrs =
      params
      |> Map.take(["plan_key", "billing_cycle", "status", "credits_adjustment"])
      |> maybe_parse_int("credits_adjustment")

    with %{} = sub <- Admin.get_subscription(id),
         {:ok, updated} <- Admin.update_subscription(sub, attrs, actor) do
      json(conn, %{data: subscription_json(updated)})
    end
  end

  # ---------- Invoices ----------

  def list_invoices(conn, params) do
    result = Admin.list_invoices(params)

    json(conn, %{
      data: Enum.map(result.data, &admin_invoice/1),
      meta: page_meta(result)
    })
  end

  def show_invoice(conn, %{"id" => id}) do
    case Admin.get_invoice(id) do
      nil -> {:error, :not_found}
      inv -> json(conn, %{data: admin_invoice(inv)})
    end
  end

  def mark_invoice_paid(conn, %{"id" => id}) do
    with %{} = inv <- Admin.get_invoice(id),
         {:ok, paid} <- Admin.mark_invoice_paid(inv, current_user(conn)) do
      json(conn, %{data: admin_invoice(paid)})
    end
  end

  def void_invoice(conn, %{"id" => id}) do
    with %{} = inv <- Admin.get_invoice(id),
         {:ok, voided} <- Admin.void_invoice(inv, current_user(conn)) do
      json(conn, %{data: admin_invoice(voided)})
    end
  end

  # ---------- Credits ----------

  def list_credit_transactions(conn, params) do
    result = Admin.list_credit_transactions(params)

    json(conn, %{
      data: Enum.map(result.data, &credit_txn_json/1),
      meta: page_meta(result)
    })
  end

  def list_usage_events(conn, params) do
    result = Admin.list_usage_events(params)

    json(conn, %{
      data: Enum.map(result.data, &usage_event_json/1),
      meta: page_meta(result)
    })
  end

  def adjust_credits(conn, %{"workspace_id" => workspace_id, "amount" => amount} = params)
      when is_integer(amount) do
    with {:ok, sub} <- Admin.adjust_credits(workspace_id, amount, current_user(conn)) do
      json(conn, %{
        data: %{
          workspace_id: workspace_id,
          credits_balance: sub.credits_balance,
          included_credits_remaining: sub.included_credits_remaining,
          description: params["description"]
        }
      })
    end
  end

  def adjust_credits(conn, %{"amount" => amount} = params)
      when is_binary(amount) do
    case Integer.parse(amount) do
      {n, _} ->
        adjust_credits(conn, Map.put(params, "amount", n))

      :error ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: %{code: "bad_request", message: "amount must be an integer"}})
    end
  end

  def adjust_credits(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      error: %{code: "bad_request", message: "workspace_id and amount are required"}
    })
  end

  # ---------- Audit ----------

  def list_audit_logs(conn, params) do
    result = Admin.list_audit_logs(params)

    json(conn, %{
      data: Enum.map(result.data, &audit_log_json/1),
      meta: page_meta(result)
    })
  end

  # ---------- Members ----------

  def list_members(conn, params) do
    result = Admin.list_members(params)

    json(conn, %{
      data: Enum.map(result.data, &admin_member/1),
      meta: page_meta(result)
    })
  end

  def update_member(conn, %{"id" => id} = params) do
    actor = current_user(conn)

    member =
      Mokaid.Repo.get(Mokaid.Members.Member, id)
      |> then(&if(&1, do: Mokaid.Repo.preload(&1, [:user, :role, :workspace])))

    with %{} = member <- member,
         {:ok, updated} <- Admin.update_member(member, params, actor) do
      json(conn, %{data: admin_member(updated)})
    end
  end

  def list_invites(conn, params) do
    result = Admin.list_invites(params)

    json(conn, %{
      data:
        Enum.map(result.data, fn i ->
          %{
            id: i.id,
            email: i.email,
            status: i.status,
            workspace_id: i.workspace_id,
            workspace_name: i.workspace && i.workspace.name,
            role_name: i.role && i.role.name,
            expires_at: i.expires_at,
            inserted_at: i.inserted_at
          }
        end),
      meta: page_meta(result)
    })
  end

  def cancel_invite(conn, %{"id" => id}) do
    invite = Mokaid.Repo.get(Mokaid.Members.MemberInvite, id)

    with %{} = invite <- invite,
         {:ok, _} <- Admin.cancel_invite(invite, current_user(conn)) do
      json(conn, %{ok: true})
    end
  end

  # ---------- Serializers ----------

  defp admin_user(user) do
    Serializer.user(user)
    |> Map.put(
      :memberships,
      Enum.map(user.memberships || [], fn m ->
        %{
          id: m.id,
          workspace_id: m.workspace_id,
          workspace_name: m.workspace && m.workspace.name,
          workspace_slug: m.workspace && m.workspace.slug,
          role_name: m.role && m.role.name,
          status: m.status,
          title: m.title,
          joined_at: m.joined_at
        }
      end)
    )
  end

  defp admin_member(m) do
    Serializer.member(m)
    |> Map.merge(%{
      workspace_id: m.workspace_id,
      workspace_name: m.workspace && m.workspace.name,
      user_email: m.user && m.user.email,
      user_full_name: m.user && m.user.full_name
    })
  end

  defp subscription_json(nil), do: nil

  defp subscription_json(sub) do
    plan = loaded(sub.plan)
    workspace = loaded(sub.workspace)

    %{
      id: sub.id,
      workspace_id: sub.workspace_id,
      workspace_name: workspace && workspace.name,
      workspace_slug: workspace && workspace.slug,
      status: sub.status,
      billing_cycle: sub.billing_cycle,
      current_period_start: sub.current_period_start,
      current_period_end: sub.current_period_end,
      credits_balance: sub.credits_balance,
      monthly_credits: sub.monthly_credits,
      included_credits_remaining: sub.included_credits_remaining,
      auto_recharge_enabled: sub.auto_recharge_enabled,
      renewal_failures: sub.renewal_failures,
      plan:
        if plan do
          plan_json(plan)
        else
          nil
        end,
      inserted_at: sub.inserted_at,
      updated_at: sub.updated_at
    }
  end

  defp plan_json(plan) do
    %{
      id: plan.id,
      key: plan.key,
      name: plan.name,
      price_cents_monthly: plan.price_cents_monthly,
      price_cents_yearly: plan.price_cents_yearly,
      limits: plan.limits,
      features: plan.features
    }
  end

  defp admin_invoice(inv) do
    Serializer.invoice(inv)
    |> Map.merge(%{
      workspace_id: inv.workspace_id,
      workspace_name: inv.workspace && inv.workspace.name,
      kind: inv.kind,
      external_payment_id: inv.external_payment_id
    })
  end

  defp credit_txn_json(txn) do
    %{
      id: txn.id,
      workspace_id: txn.workspace_id,
      kind: txn.kind,
      amount: txn.amount,
      cost_cents: txn.cost_cents,
      balance_after: txn.balance_after,
      description: txn.description,
      metadata: txn.metadata,
      inserted_at: txn.inserted_at
    }
  end

  defp usage_event_json(e) do
    quantity =
      case e.quantity do
        %Decimal{} = d -> Decimal.to_float(d)
        other -> other
      end

    %{
      id: e.id,
      workspace_id: e.workspace_id,
      actor_type: e.actor_type,
      actor_id: e.actor_id,
      event_type: e.event_type,
      quantity: quantity,
      unit: e.unit,
      cost_cents: e.cost_cents,
      metadata: e.metadata,
      occurred_at: e.occurred_at
    }
  end

  defp audit_log_json(l) do
    %{
      id: l.id,
      workspace_id: l.workspace_id,
      actor_type: l.actor_type,
      actor_id: l.actor_id,
      actor_name: l.actor_name,
      action: l.action,
      resource_type: l.resource_type,
      resource_id: l.resource_id,
      ip_address: l.ip_address,
      user_agent: l.user_agent,
      metadata: l.metadata,
      occurred_at: l.occurred_at
    }
  end

  defp page_meta(result) do
    %{
      page: result.page,
      per_page: result.per_page,
      total: result.total,
      total_pages: ceil(result.total / max(result.per_page, 1))
    }
  end

  defp maybe_parse_int(map, key) do
    case Map.get(map, key) do
      v when is_binary(v) ->
        case Integer.parse(v) do
          {n, _} -> Map.put(map, key, n)
          :error -> map
        end

      _ ->
        map
    end
  end

  defp loaded(%Ecto.Association.NotLoaded{}), do: nil
  defp loaded(v), do: v
end
