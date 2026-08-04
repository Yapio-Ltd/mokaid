defmodule Mokaid.AI.Orchestrator do
  @moduledoc """
  Composite missions: one request that asks for several distinct deliverables
  ("full branding + website + admin CRM") is decomposed into child tasks
  executed in dependency waves by the best-fit agent for each deliverable.

  Wave ordering encodes real handoffs: research feeds branding, branding feeds
  the website/app build, and reports/presentations come last. Every artifact a
  child produces (Drive file linked to the child task) is attached to the next
  wave's missions, so e.g. the web developer receives the logo the designer
  just made.

  The parent task acts as the mission control surface: one subtask per child
  (checked off as children finish), progress % = finished children, and it
  flips to "in_review" only when the whole plan is done.
  """

  import Ecto.Query

  alias Mokaid.AI.Dispatcher
  alias Mokaid.Drive.DriveItem
  alias Mokaid.Repo
  alias Mokaid.Tasks
  alias Mokaid.Tasks.Task, as: WorkTask

  # Each deliverable a request can ask for, with the wave it runs in.
  # Patterns match the downcased instruction; two or more distinct
  # deliverables make the request composite.
  @deliverables [
    %{
      key: "research",
      wave: 1,
      pattern:
        ~r/recherche|étude de marché|etude de marche|market research|benchmark|veille concurrentielle|analyse concurrent|competitive analysis/u,
      title: {"Étude & recherche", "Research & discovery"},
      focus:
        {"l'étude et la recherche (marché, concurrence, références) pour alimenter les autres volets",
         "the research and discovery work (market, competitors, references) feeding the other tracks"}
    },
    %{
      key: "branding",
      wave: 2,
      pattern:
        ~r/logo|branding|identité visuelle|identite visuelle|charte graphique|brand identity|direction artistique/u,
      title: {"Branding & identité visuelle", "Branding & visual identity"},
      focus:
        {"le branding : logo, palette, typographies et charte graphique",
         "the branding: logo, palette, typography and brand guidelines"}
    },
    %{
      key: "website",
      wave: 3,
      pattern: ~r/site (web|internet|vitrine)|website|landing ?page|page web|web ?app/u,
      title: {"Site web", "Website"},
      focus:
        {"le site web complet, en réutilisant le branding produit par les vagues précédentes",
         "the complete website, reusing the branding produced by earlier waves"}
    },
    %{
      key: "app",
      wave: 3,
      pattern:
        ~r/\bcrm\b|\berp\b|application mobile|mobile app|back.?office|tableau de bord|dashboard|admin (complet|panel|interface)/u,
      title: {"Application / CRM", "Application / CRM"},
      focus:
        {"l'application (CRM / admin / dashboard) : structure, écrans et fonctionnalités",
         "the application (CRM / admin / dashboard): structure, screens and features"}
    },
    %{
      key: "report",
      wave: 4,
      pattern:
        ~r/rapport|compte.?rendu|\breport\b|présentation|presentation|pitch ?deck|business ?plan|slides/u,
      title: {"Rapport & synthèse", "Report & summary"},
      focus:
        {"le rapport final : synthèse de tout ce qui a été produit, avec recommandations",
         "the final report: a synthesis of everything produced, with recommendations"}
    }
  ]

  @doc "True when the instruction asks for two or more distinct deliverables."
  def composite?(instruction) when is_binary(instruction) do
    length(detect_deliverables(instruction)) >= 2
  end

  def composite?(_), do: false

  @doc """
  Decomposes the parent task into child tasks grouped in waves, assigns each
  to the best-fit agent, and starts every mission of the first wave.

  Returns `{:ok, %{children: [task], waves: n}}` or `:not_composite`.
  """
  def launch(workspace_id, %WorkTask{} = parent, instruction, member \\ nil) do
    case detect_deliverables(instruction) do
      deliverables when length(deliverables) >= 2 ->
        french? = french?(instruction)

        children =
          deliverables
          |> Enum.sort_by(& &1.wave)
          |> Enum.map(fn deliverable ->
            create_child(workspace_id, parent, instruction, deliverable, french?, member)
          end)

        waves =
          children
          |> Enum.group_by(fn {wave, _task} -> wave end, fn {_wave, task} -> task.id end)
          |> Map.new(fn {wave, ids} -> {to_string(wave), ids} end)

        first_wave = children |> Enum.map(fn {wave, _} -> wave end) |> Enum.min()
        child_tasks = Enum.map(children, fn {_wave, task} -> task end)

        {:ok, _} =
          Tasks.update_task(parent, %{
            "status" => "in_progress",
            "metadata" =>
              Map.merge(parent.metadata || %{}, %{
                "composite" => %{
                  "child_ids" => Enum.map(child_tasks, & &1.id),
                  "waves" => waves,
                  "current_wave" => first_wave,
                  "total" => length(child_tasks)
                }
              })
          })

        start_wave(workspace_id, Map.get(waves, to_string(first_wave), []), [])

        {:ok, %{children: child_tasks, waves: map_size(waves)}}

      _ ->
        :not_composite
    end
  end

  @doc """
  Called whenever a task completes a run: when the task is a composite child
  and its whole wave is done, launches the next wave with the artifacts
  produced so far attached — or moves the parent to review when the plan is
  finished. No-op for regular tasks.
  """
  def maybe_advance(%WorkTask{} = child) do
    parent_id = get_in(child.metadata || %{}, ["composite_parent_id"])

    if is_binary(parent_id) do
      check_off_subtask(child)

      # Serialized on the parent row so two children finishing at the same
      # time cannot both launch the next wave.
      Repo.transaction(fn ->
        parent =
          Repo.one(
            from t in WorkTask,
              where: t.workspace_id == ^child.workspace_id and t.id == ^parent_id,
              lock: "FOR UPDATE"
          )

        if parent, do: advance(parent)
      end)
    end

    :ok
  end

  def maybe_advance(_), do: :ok

  ## ---------- Internals ----------

  defp advance(%WorkTask{} = parent) do
    composite = get_in(parent.metadata || %{}, ["composite"]) || %{}
    waves = composite["waves"] || %{}
    current = composite["current_wave"]
    child_ids = composite["child_ids"] || []

    done_ids = finished_children(parent.workspace_id, child_ids)
    update_progress(parent, done_ids, child_ids)

    wave_ids = Map.get(waves, to_string(current), [])

    if current != nil and Enum.all?(wave_ids, &(&1 in done_ids)) do
      case next_wave(waves, current) do
        nil ->
          finish(parent)

        next ->
          artifacts = artifact_ids(parent.workspace_id, done_ids)
          start_wave(parent.workspace_id, Map.get(waves, to_string(next), []), artifacts)

          meta = parent.metadata || %{}
          composite_meta = Map.get(meta, "composite") || %{}

          {:ok, _} =
            Tasks.update_task(parent, %{
              "metadata" =>
                Map.put(meta, "composite", Map.put(composite_meta, "current_wave", next))
            })
      end
    end
  end

  defp next_wave(waves, current) do
    waves
    |> Map.keys()
    |> Enum.map(&String.to_integer/1)
    |> Enum.filter(&(&1 > current))
    |> Enum.min(fn -> nil end)
  end

  defp finish(%WorkTask{} = parent) do
    unless parent.status in ["completed", "canceled", "in_review"] do
      {:ok, _} = Tasks.update_task(parent, %{"status" => "in_review", "progress_percent" => 100})
    end
  end

  defp update_progress(%WorkTask{} = parent, done_ids, child_ids) do
    total = max(length(child_ids), 1)
    percent = min(div(length(done_ids) * 100, total), 100)

    if parent.status not in ["completed", "canceled"] and
         percent != (parent.progress_percent || 0) do
      Tasks.update_task(parent, %{"progress_percent" => percent})
    end
  end

  # Children that reached a successful terminal state (their run produced
  # output and the task is waiting for / passed human review).
  defp finished_children(workspace_id, child_ids) do
    Repo.all(
      from t in WorkTask,
        where:
          t.workspace_id == ^workspace_id and t.id in ^child_ids and
            t.status in ["in_review", "completed"],
        select: t.id
    )
  end

  # Drive files produced under the finished children — the handoff payload.
  defp artifact_ids(workspace_id, child_ids) do
    Repo.all(
      from d in DriveItem,
        where:
          d.workspace_id == ^workspace_id and d.kind == "file" and d.status == "active" and
            d.linked_task_id in ^child_ids,
        select: d.id
    )
  end

  defp start_wave(workspace_id, task_ids, artifact_ids) do
    for task_id <- task_ids,
        task = Tasks.get_task(workspace_id, task_id),
        task != nil,
        task.status not in ["completed", "in_review", "canceled"] do
      task =
        if artifact_ids == [] do
          task
        else
          existing = List.wrap(get_in(task.metadata || %{}, ["drive_item_ids"]))

          {:ok, updated} =
            Tasks.update_task(task, %{
              "metadata" =>
                Map.put(
                  task.metadata || %{},
                  "drive_item_ids",
                  Enum.uniq(existing ++ artifact_ids)
                )
            })

          updated
        end

      agent =
        task.assigned_agent_id && Mokaid.Agents.get_agent(workspace_id, task.assigned_agent_id)

      if agent && agent.kind != "human_linked" do
        Mokaid.AI.start_run(task, %{
          "instruction" => get_in(task.metadata || %{}, ["instruction"]) || task.description,
          "drive_item_ids" => List.wrap(get_in(task.metadata || %{}, ["drive_item_ids"]))
        })
      end
    end

    :ok
  end

  defp create_child(workspace_id, parent, instruction, deliverable, french?, member) do
    title = pick_lang(deliverable.title, french?)
    brief = child_brief(instruction, deliverable, french?)
    agent = Dispatcher.best_agent(workspace_id, "#{title}. #{brief}")

    {:ok, subtask} = Tasks.create_subtask(parent, %{"title" => title})

    {:ok, child} =
      Tasks.create_task(
        workspace_id,
        %{
          "title" => "#{parent.title} — #{title}",
          "description" => brief,
          "priority" => parent.priority,
          "project_id" => parent.project_id,
          "assigned_agent_id" => agent && agent.id,
          "metadata" => %{
            "source" => "composite",
            "instruction" => brief,
            "composite_parent_id" => parent.id,
            "composite_wave" => deliverable.wave,
            "composite_key" => deliverable.key,
            "composite_subtask_id" => subtask.id,
            "drive_item_ids" => List.wrap(get_in(parent.metadata || %{}, ["drive_item_ids"]))
          }
        },
        member
      )

    {deliverable.wave, child}
  end

  defp child_brief(instruction, deliverable, french?) do
    focus = pick_lang(deliverable.focus, french?)
    head = focus_headline(deliverable.key, french?)

    context =
      if french? do
        "Sous-mission d'une mission composite. Concentre-toi UNIQUEMENT sur #{focus}. " <>
          "Les autres volets sont pris en charge par d'autres agents ; les livrables des vagues " <>
          "précédentes sont joints à cette mission comme fichiers. N'essaie pas de tout faire."
      else
        "Sub-mission of a composite mission. Focus ONLY on #{focus}. " <>
          "Other tracks are handled by other agents; deliverables from earlier waves are " <>
          "attached to this mission as files. Do not try to do everything."
      end

    # Lead with a single-purpose headline so mission_kind / tool forcing pick the
    # right producer. Parent text is context only (truncated).
    parent_ctx = String.slice(String.trim(instruction || ""), 0, 500)

    "#{head}\n\n#{context}\n\nParent context (for orientation only):\n#{parent_ctx}"
  end

  defp focus_headline("research", true),
    do: "Recherche et étude de marché uniquement (livrable rapport/synthèse)."

  defp focus_headline("research", false),
    do: "Research and market study only (report/summary deliverable)."

  defp focus_headline("branding", true),
    do: "Branding et identité visuelle uniquement : logo, palette, charte."

  defp focus_headline("branding", false),
    do: "Branding and visual identity only: logo, palette, guidelines."

  defp focus_headline("website", true),
    do: "Site web vitrine / landing page uniquement (HTML ou Next)."

  defp focus_headline("website", false),
    do: "Website / landing page only (HTML or Next)."

  defp focus_headline("app", true),
    do: "Application CRM / admin / dashboard React Next.js TypeScript uniquement."

  defp focus_headline("app", false),
    do: "CRM / admin / dashboard application only (React Next.js TypeScript)."

  defp focus_headline("report", true),
    do: "Rapport PDF et synthèse finale uniquement."

  defp focus_headline("report", false),
    do: "Final PDF report and summary only."

  defp focus_headline(_, true), do: "Sous-mission composite — focus sur ton livrable."
  defp focus_headline(_, false), do: "Composite sub-mission — focus on your deliverable."

  defp check_off_subtask(%WorkTask{} = child) do
    with parent_id when is_binary(parent_id) <-
           get_in(child.metadata || %{}, ["composite_parent_id"]),
         subtask_id when is_binary(subtask_id) <-
           get_in(child.metadata || %{}, ["composite_subtask_id"]),
         %WorkTask{} = parent <- Tasks.get_task(child.workspace_id, parent_id),
         subtask when subtask != nil <- Tasks.get_subtask(parent, subtask_id) do
      unless subtask.done, do: Tasks.update_subtask(subtask, %{"done" => true})
    else
      _ -> :ok
    end
  end

  defp detect_deliverables(instruction) do
    text = String.downcase(instruction || "")
    Enum.filter(@deliverables, fn d -> Regex.match?(d.pattern, text) end)
  end

  @french_markers ~w(le la les des une pour avec est sont notre votre je nous faut complet)
  defp french?(instruction) do
    words =
      instruction |> String.downcase() |> String.split(~r/[^a-zà-ÿ]+/u, trim: true)

    Enum.count(words, &(&1 in @french_markers)) >= 2
  end

  defp pick_lang({fr, _en}, true), do: fr
  defp pick_lang({_fr, en}, false), do: en
end
