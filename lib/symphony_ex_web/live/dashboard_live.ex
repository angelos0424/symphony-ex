defmodule SymphonyExWeb.DashboardLive do
  @moduledoc """
  Runtime dashboard for the Symphony orchestrator.

  This Phase 3.4.4 slice strengthens the dashboard controls with richer
  filtering/sorting and adds an optional full-page run detail route while
  keeping the runtime snapshot foundation intact.
  """

  use SymphonyExWeb, :live_view

  alias SymphonyEx.{Dashboard, RuntimeControl, RuntimeSnapshot}

  @default_filters %{
    "q" => "",
    "queue" => "all",
    "class" => "all",
    "result" => "all",
    "status" => "all",
    "error_category" => "",
    "active_sort" => "default",
    "completed_sort" => "newest",
    "completed_window" => "all",
    "completed_limit" => "10"
  }

  @queue_options [
    {"All queues", "all"},
    {"Running only", "running"},
    {"Retry only", "retry_queue"},
    {"Completed only", "completed"}
  ]

  @class_options [
    {"All classes", "all"},
    {"Code", "code"},
    {"Docs", "docs"},
    {"Infra", "infra"},
    {"Other / uncategorized", "other"}
  ]

  @result_options [
    {"All outcomes", "all"},
    {"Success only", "success"},
    {"Failed only", "failed"},
    {"Cancelled only", "cancelled"}
  ]

  @status_options [
    {"All retry/completion statuses", "all"},
    {"Success", "success"},
    {"Failed", "failed"},
    {"Cancelled", "cancelled"}
  ]

  @active_sort_options [
    {"Default queue order", "default"},
    {"Oldest started / queued first", "oldest"},
    {"Longest waiting / running first", "longest"},
    {"Highest priority first", "priority_desc"},
    {"Identifier A→Z", "identifier_asc"}
  ]

  @completed_sort_options [
    {"Newest first", "newest"},
    {"Oldest first", "oldest"},
    {"Longest runtime", "runtime_desc"},
    {"Shortest runtime", "runtime_asc"},
    {"Identifier A→Z", "identifier_asc"},
    {"Highest priority first", "priority_desc"}
  ]

  @completed_window_options [
    {"All recorded completions", "all"},
    {"Last 24 hours", "24h"},
    {"Last 3 days", "3d"},
    {"Last 7 days", "7d"}
  ]

  @completed_limit_options [
    {"10 rows", "10"},
    {"25 rows", "25"},
    {"50 rows", "50"},
    {"100 rows", "100"}
  ]

  @error_category_options [
    {"Any category", ""},
    {"turn_failed", "turn_failed"},
    {"timeout", "timeout"},
    {"cancelled", "cancelled"},
    {"conflict", "conflict"},
    {"rate_limited", "rate_limited"},
    {"tool_error", "tool_error"},
    {"Custom…", "__custom__"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(SymphonyEx.PubSub, Dashboard.topic())
    end

    {:ok,
     socket
     |> assign(:page_title, "Symphony Dashboard")
     |> assign(:filters, @default_filters)
     |> assign(:selected_identifier, nil)
     |> assign(:queue_options, @queue_options)
     |> assign(:class_options, @class_options)
     |> assign(:result_options, @result_options)
     |> assign(:status_options, @status_options)
     |> assign(:active_sort_options, @active_sort_options)
     |> assign(:completed_sort_options, @completed_sort_options)
     |> assign(:completed_window_options, @completed_window_options)
     |> assign(:completed_limit_options, @completed_limit_options)
     |> assign(:error_category_options, @error_category_options)
     |> assign_snapshot(current_snapshot())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = normalize_filters(params)
    selected_identifier = normalize_identifier(params["run"] || params["identifier"])
    live_action = socket.assigns.live_action

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:selected_identifier, selected_identifier)
     |> assign(:page_title, page_title(live_action, selected_identifier))
     |> assign_snapshot(socket.assigns.snapshot)}
  end

  @impl true
  def handle_event("apply_filters", %{"filters" => params}, socket) do
    filters = normalize_filters(params)

    {:noreply,
     push_patch(socket,
       to:
         dashboard_path(filters, socket.assigns[:selected_identifier], socket.assigns.live_action),
       replace: true
     )}
  end

  @impl true
  def handle_event("save_runtime_settings", %{"runtime" => params}, socket) do
    case RuntimeControl.apply_orchestrator_settings(params) do
      {:ok, _result} ->
        {:noreply,
         socket
         |> put_flash(:info, "Saved WORKFLOW orchestrator settings and reloaded runtime config.")
         |> assign_snapshot(current_snapshot())}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, runtime_control_error(reason))}
    end
  end

  @impl true
  def handle_event("restart_component", %{"component" => component}, socket) do
    case component_from_param(component) do
      {:ok, component_name} ->
        case RuntimeControl.restart_component(component_name) do
          {:ok, :orchestrator} ->
            {:noreply,
             socket
             |> put_flash(:info, "Restarted orchestrator.")
             |> assign_snapshot(current_snapshot())}

          {:ok, :endpoint} ->
            {:noreply,
             put_flash(
               socket,
               :info,
               "Restarted dashboard endpoint. Refresh if this LiveView disconnects."
             )}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, runtime_control_error(reason))}
        end

      :error ->
        {:noreply, put_flash(socket, :error, "Unknown runtime component.")}
    end
  end

  @impl true
  def handle_info({:runtime_snapshot_updated, snapshot}, socket) do
    {:noreply, assign_snapshot(socket, snapshot)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <style>
      .dashboard-shell { font-family: Inter, system-ui, sans-serif; margin: 0 auto; max-width: 1320px; padding: 24px; color: #111827; background: #f8fafc; min-height: 100vh; }
      .dashboard-content-grid { display: grid; gap: 16px; grid-template-columns: minmax(0, 2fr) minmax(320px, 1fr); align-items: start; }
      .dashboard-sidebar { display: grid; gap: 16px; position: sticky; top: 16px; }
      .dashboard-summary-grid { display: grid; gap: 12px; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); margin-bottom: 24px; }
      .dashboard-filters-grid { display: grid; gap: 12px; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); align-items: end; }
      .dashboard-field-span-2 { grid-column: span 2; }

      @media (max-width: 1024px) {
        .dashboard-content-grid { grid-template-columns: minmax(0, 1fr); }
        .dashboard-sidebar { position: static; top: auto; }
      }

      @media (max-width: 720px) {
        .dashboard-shell { padding: 16px; }
        .dashboard-filters-grid { grid-template-columns: minmax(0, 1fr); }
        .dashboard-field-span-2 { grid-column: auto; }
      }
    </style>

    <div class="dashboard-shell">
      <header style="margin-bottom: 24px;">
        <p style="margin: 0; color: #6b7280; font-size: 14px;">Phase 3.4.4</p>
        <h1 style="margin: 4px 0 8px; font-size: 32px;">Symphony runtime dashboard</h1>
        <p style="margin: 0; color: #4b5563; max-width: 900px; line-height: 1.5;">
          This slice adds stronger class/outcome controls, broader active queue sorting,
          and an optional full-page run detail route on top of the shared runtime snapshot.
        </p>
      </header>

      <%= if message = flash_message(@flash, :info) do %>
        <section style={flash_style(:info)}>{message}</section>
      <% end %>

      <%= if message = flash_message(@flash, :error) do %>
        <section style={flash_style(:error)}>{message}</section>
      <% end %>

      <%= if @live_action == :show && @selected_run do %>
        <section style={panel_style() <> " margin-bottom: 16px;"}>
          <div style="display: flex; justify-content: space-between; gap: 12px; align-items: baseline; flex-wrap: wrap;">
            <div>
              <h2 style="margin: 0; font-size: 20px;">Run detail route</h2>
              <p style="margin: 4px 0 0; color: #6b7280; font-size: 13px;">
                Full-page inspection view for deep runtime breadcrumbs without the split layout squeeze.
              </p>
            </div>
            <div style="display: flex; gap: 12px; flex-wrap: wrap; align-items: center;">
              <.link navigate={dashboard_path(@filters, nil, :index)} style="font-size: 13px; color: #2563eb; text-decoration: none;">Back to dashboard</.link>
              <%= if active_filters?(@filters) do %>
                <.link patch={dashboard_path(default_filters(), @selected_identifier, :show)} style="font-size: 13px; color: #2563eb; text-decoration: none;">Clear filters</.link>
              <% end %>
            </div>
          </div>
        </section>
      <% end %>

      <section style={panel_style() <> " margin-bottom: 16px;"}>
        <div style="display: flex; justify-content: space-between; gap: 12px; align-items: baseline; flex-wrap: wrap; margin-bottom: 12px;">
          <div>
            <h2 style="margin: 0; font-size: 20px;">Filters & sorting</h2>
            <p style={muted_text_style()}>Search by identifier, title, label, assignee, workspace, session, or conflict hint, then narrow by class, completed outcome, shared retry/completion status, error category, and the completion history window / row count.</p>
          </div>
          <div style="display: flex; gap: 12px; flex-wrap: wrap; align-items: center;">
            <%= if active_filters?(@filters) do %>
              <.link patch={dashboard_path(default_filters(), @selected_identifier, @live_action)} style="font-size: 13px; color: #2563eb; text-decoration: none;">Clear filters</.link>
            <% end %>
            <%= if @selected_run && @live_action == :index do %>
              <.link patch={dashboard_path(@filters, nil, :index)} style="font-size: 13px; color: #2563eb; text-decoration: none;">Close inspector</.link>
            <% end %>
          </div>
        </div>

        <.form for={%{}} as={:filters} phx-change="apply_filters" class="dashboard-filters-grid">
          <label style={field_label_style()}>
            Search
            <input type="text" name="filters[q]" value={@filters["q"]} placeholder="SYM-123, api, blocked…" style={input_style()} />
          </label>

          <label style={field_label_style()}>
            Queue focus
            <select name="filters[queue]" style={input_style()}>
              <%= for {label, value} <- @queue_options do %>
                <option value={value} selected={@filters["queue"] == value}>{label}</option>
              <% end %>
            </select>
          </label>

          <label style={field_label_style()}>
            Concurrency class
            <select name="filters[class]" style={input_style()}>
              <%= for {label, value} <- @class_options do %>
                <option value={value} selected={@filters["class"] == value}>{label}</option>
              <% end %>
            </select>
          </label>

          <label style={field_label_style()}>
            Completed outcome
            <select name="filters[result]" style={input_style()}>
              <%= for {label, value} <- @result_options do %>
                <option value={value} selected={@filters["result"] == value}>{label}</option>
              <% end %>
            </select>
          </label>

          <label style={field_label_style()}>
            Retry / completion status
            <select name="filters[status]" style={input_style()}>
              <%= for {label, value} <- @status_options do %>
                <option value={value} selected={@filters["status"] == value}>{label}</option>
              <% end %>
            </select>
          </label>

          <label style={field_label_style()}>
            Error category
            <select name="filters[error_category]" style={input_style()}>
              <%= for {label, value} <- @error_category_options do %>
                <option value={value} selected={selected_error_category?(@filters, value)}>{label}</option>
              <% end %>
            </select>
          </label>

          <label :if={custom_error_category?(@filters)} style={field_label_style()} class="dashboard-field-span-2">
            Custom error category contains
            <input
              type="text"
              name="filters[error_category_custom]"
              value={custom_error_category_value(@filters)}
              placeholder="timeout, turn_failed…"
              style={input_style()}
            />
          </label>

          <label style={field_label_style()}>
            Active queue sort
            <select name="filters[active_sort]" style={input_style()}>
              <%= for {label, value} <- @active_sort_options do %>
                <option value={value} selected={@filters["active_sort"] == value}>{label}</option>
              <% end %>
            </select>
          </label>

          <label style={field_label_style()}>
            Completed sort
            <select name="filters[completed_sort]" style={input_style()}>
              <%= for {label, value} <- @completed_sort_options do %>
                <option value={value} selected={@filters["completed_sort"] == value}>{label}</option>
              <% end %>
            </select>
          </label>

          <label style={field_label_style()}>
            History window
            <select name="filters[completed_window]" style={input_style()}>
              <%= for {label, value} <- @completed_window_options do %>
                <option value={value} selected={@filters["completed_window"] == value}>{label}</option>
              <% end %>
            </select>
          </label>

          <label style={field_label_style()}>
            Completed rows
            <select name="filters[completed_limit]" style={input_style()}>
              <%= for {label, value} <- @completed_limit_options do %>
                <option value={value} selected={@filters["completed_limit"] == value}>{label}</option>
              <% end %>
            </select>
          </label>
        </.form>

        <div style="display: grid; gap: 8px; margin-top: 12px;">
          <div style={muted_text_style()}>
            Showing {view_total_count(@view)} matched issue(s) across running, retry, and completed sections.
          </div>

          <%= if active_filter_chips(@filters) != [] do %>
            <div style="display: flex; gap: 8px; flex-wrap: wrap;">
              <%= for chip <- active_filter_chips(@filters) do %>
                <span style={pill_style(:neutral)}>{chip}</span>
              <% end %>
            </div>
          <% end %>
        </div>
      </section>

      <section class="dashboard-summary-grid">
        <%= for card <- summary_cards(@snapshot.summary) do %>
          <article style="background: white; border: 1px solid #e5e7eb; border-radius: 14px; padding: 16px; box-shadow: 0 1px 2px rgba(15, 23, 42, 0.04);">
            <div style="color: #6b7280; font-size: 13px; margin-bottom: 6px;">{card.label}</div>
            <div style="font-size: 28px; font-weight: 700;">{card.value}</div>
          </article>
        <% end %>
      </section>

      <%= if @live_action == :show do %>
        <div style="display: grid; gap: 16px;">
          <%= if @selected_run do %>
            <section style={panel_style()}>
              <.run_detail_panel run={@selected_run} filters={@filters} detail_mode={:full_page} />
            </section>
          <% else %>
            <section style={panel_style()}>
              <h2 style="margin-top: 0; font-size: 20px;">Run detail route</h2>
              <p style="margin: 8px 0 0; color: #6b7280; line-height: 1.5;">
                The requested run is not present in the current runtime snapshot. Return to the dashboard to pick another run.
              </p>
            </section>
          <% end %>

          <section style={panel_style()}>
            <h2 style="margin-top: 0; font-size: 20px;">Orchestrator settings</h2>
            <dl style="display: grid; grid-template-columns: minmax(0, 1fr); gap: 10px; margin: 0;">
              <%= for {label, value} <- settings_rows(@snapshot.settings) do %>
                <div>
                  <dt style={dt_style()}>{label}</dt>
                  <dd style={dd_style()}>{value}</dd>
                </div>
              <% end %>
            </dl>
          </section>

          <section style={panel_style()}>
            <h2 style="margin-top: 0; font-size: 20px;">Recent tracker write-back</h2>
            <.write_back_stage_list entries={@snapshot.write_back_stages.recent} empty_message="No tracker write-back activity has been recorded yet." />
          </section>
        </div>
      <% else %>
        <div class="dashboard-content-grid">
          <div style="display: grid; gap: 16px;">
            <%= if queue_visible?(@filters, "running") do %>
              <section style={panel_style()}>
                <div style="display: flex; justify-content: space-between; gap: 12px; align-items: baseline; flex-wrap: wrap; margin-bottom: 12px;">
                  <h2 style="margin: 0; font-size: 20px;">Running issues</h2>
                  <span style="color: #6b7280; font-size: 13px;">{length(@view.running)} matching issue(s)</span>
                </div>
                <%= if @view.running == [] do %>
                  <p style="color: #6b7280; margin-bottom: 0;">{empty_message(@filters, "running", "No issues are running right now.")}</p>
                <% else %>
                  <div style="display: grid; gap: 12px;">
                    <%= for entry <- @view.running do %>
                      <article style={entry_card_style(entry, @selected_identifier)}>
                        <div style="display: flex; justify-content: space-between; gap: 12px; flex-wrap: wrap;">
                          <div>
                            <div style="font-size: 12px; color: #6b7280; text-transform: uppercase;">{entry.issue.identifier}</div>
                            <div style="font-size: 18px; font-weight: 600;">{entry.issue.title}</div>
                          </div>
                          <div style="display: flex; gap: 8px; flex-wrap: wrap; justify-content: flex-end; align-items: center;">
                            <span style={pill_style(:running)}>{entry.state}</span>
                            <span style={pill_style(:neutral)}>{entry.concurrency_class}</span>
                            <span style={pill_style(:neutral)}>priority {priority_value(entry)}</span>
                            <span style={pill_style(:neutral)}>attempt {entry.attempt}</span>
                            <span style={pill_style(:info)}>running {format_duration(entry.elapsed_ms)}</span>
                            <.link patch={dashboard_path(@filters, entry.issue.identifier, :index)} style={action_link_style()}>Inspect run</.link>
                            <.link navigate={dashboard_path(@filters, entry.issue.identifier, :show)} style={action_link_style()}>Open full page</.link>
                          </div>
                        </div>

                        <dl style="display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 8px 12px; margin: 12px 0 0;">
                          <div>
                            <dt style={dt_style()}>Started</dt>
                            <dd style={dd_style()}>{format_timestamp(entry.started_at)}</dd>
                          </div>
                          <div>
                            <dt style={dt_style()}>Workspace</dt>
                            <dd style={dd_style()}><code>{entry.workspace_path}</code></dd>
                          </div>
                          <div>
                            <dt style={dt_style()}>Conflict keys</dt>
                            <dd style={dd_style()}>{joined(entry.conflict_keys)}</dd>
                          </div>
                          <div>
                            <dt style={dt_style()}>Labels</dt>
                            <dd style={dd_style()}>{joined(entry.issue.labels)}</dd>
                          </div>
                        </dl>
                      </article>
                    <% end %>
                  </div>
                <% end %>
              </section>
            <% end %>

            <%= if queue_visible?(@filters, "retry_queue") do %>
              <section style={panel_style()}>
                <div style="display: flex; justify-content: space-between; gap: 12px; align-items: baseline; flex-wrap: wrap; margin-bottom: 12px;">
                  <h2 style="margin: 0; font-size: 20px;">Retry queue</h2>
                  <span style="color: #92400e; font-size: 13px;">{length(@view.retry_queue)} matching issue(s)</span>
                </div>
                <%= if @view.retry_queue == [] do %>
                  <p style="color: #6b7280; margin-bottom: 0;">{empty_message(@filters, "retry_queue", "Retry queue is empty.")}</p>
                <% else %>
                  <div style="display: grid; gap: 12px;">
                    <%= for entry <- @view.retry_queue do %>
                      <article style={entry_card_style(entry, @selected_identifier, "border: 1px solid #fcd34d; background: #fffbeb;")}>
                        <div style="display: flex; justify-content: space-between; gap: 12px; flex-wrap: wrap;">
                          <div>
                            <div style="font-size: 12px; color: #92400e; text-transform: uppercase;">{entry.issue.identifier}</div>
                            <div style="font-size: 18px; font-weight: 600;">{entry.issue.title}</div>
                          </div>
                          <div style="display: flex; gap: 8px; flex-wrap: wrap; justify-content: flex-end; align-items: center;">
                            <span style={pill_style(:retry)}>retry in {format_duration(entry.due_in_ms)}</span>
                            <span style={pill_style(:neutral)}>{entry.concurrency_class}</span>
                            <span style={pill_style(:neutral)}>priority {priority_value(entry)}</span>
                            <span style={pill_style(:neutral)}>attempt {entry.attempt}</span>
                            <.link patch={dashboard_path(@filters, entry.issue.identifier, :index)} style={action_link_style()}>Inspect run</.link>
                            <.link navigate={dashboard_path(@filters, entry.issue.identifier, :show)} style={action_link_style()}>Open full page</.link>
                          </div>
                        </div>

                        <dl style="display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 8px 12px; margin: 12px 0 0;">
                          <div>
                            <dt style="font-size: 12px; color: #92400e;">Retry scheduled for</dt>
                            <dd style={dd_style()}>{format_timestamp(entry.due_at)}</dd>
                          </div>
                          <div>
                            <dt style="font-size: 12px; color: #92400e;">Backoff</dt>
                            <dd style={dd_style()}>{format_duration(entry.backoff_ms)}</dd>
                          </div>
                          <div>
                            <dt style="font-size: 12px; color: #92400e;">Queued</dt>
                            <dd style={dd_style()}>{format_timestamp(entry.queued_at)} · waiting {format_duration(entry.queued_for_ms)}</dd>
                          </div>
                          <div>
                            <dt style="font-size: 12px; color: #92400e;">Conflict keys</dt>
                            <dd style={dd_style()}>{joined(entry.conflict_keys)}</dd>
                          </div>
                        </dl>

                        <details style={details_style()}>
                          <summary style={summary_style()}>Last outcome details</summary>
                          <dl style={detail_grid_style()}>
                            <div>
                              <dt style={dt_style()}>Status</dt>
                              <dd style={dd_style()}>{present(entry.last_result[:status])}</dd>
                            </div>
                            <div>
                              <dt style={dt_style()}>Error category</dt>
                              <dd style={dd_style()}>{present(entry.last_result[:error_category])}</dd>
                            </div>
                            <div>
                              <dt style={dt_style()}>Last event</dt>
                              <dd style={dd_style()}>{present(entry.last_result[:last_event])}</dd>
                            </div>
                            <div>
                              <dt style={dt_style()}>Elapsed</dt>
                              <dd style={dd_style()}>{present_duration(entry.last_result[:elapsed_ms])}</dd>
                            </div>
                            <div style="grid-column: 1 / -1;">
                              <dt style={dt_style()}>Message / details</dt>
                              <dd style={dd_style()}>{present(entry.last_result[:last_message] || entry.last_result[:error] || entry.last_result[:details])}</dd>
                            </div>
                          </dl>
                        </details>
                      </article>
                    <% end %>
                  </div>
                <% end %>
              </section>
            <% end %>

            <%= if queue_visible?(@filters, "completed") do %>
              <section style={panel_style()}>
                <div style="display: flex; justify-content: space-between; gap: 12px; align-items: baseline; flex-wrap: wrap; margin-bottom: 12px;">
                  <h2 style="margin: 0; font-size: 20px;">Recent completions</h2>
                  <span style="color: #6b7280; font-size: 13px;">{length(@view.completed)} matching issue(s)</span>
                </div>
                <%= if @view.completed == [] do %>
                  <p style="color: #6b7280; margin-bottom: 0;">{empty_message(@filters, "completed", "No completed runs recorded in the current runtime yet.")}</p>
                <% else %>
                  <div style="display: grid; gap: 12px;">
                    <%= for entry <- Enum.take(@view.completed, completed_limit(@filters)) do %>
                      <article style={entry_card_style(entry, @selected_identifier)}>
                        <div style="display: flex; justify-content: space-between; gap: 12px; flex-wrap: wrap;">
                          <div>
                            <div style="font-size: 12px; color: #6b7280; text-transform: uppercase;">{entry.issue.identifier}</div>
                            <div style="font-size: 17px; font-weight: 600;">{entry.issue.title}</div>
                          </div>
                          <div style="display: flex; gap: 8px; flex-wrap: wrap; justify-content: flex-end; align-items: center;">
                            <span style={pill_style(completed_tone(entry.result))}>{entry.result}</span>
                            <span style={pill_style(:neutral)}>priority {priority_value(entry)}</span>
                            <span style={pill_style(:neutral)}>attempt {entry.attempt}</span>
                            <span style={pill_style(:neutral)}>{format_timestamp(entry.completed_at)}</span>
                            <%= if entry.elapsed_ms do %>
                              <span style={pill_style(:info)}>runtime {format_duration(entry.elapsed_ms)}</span>
                            <% end %>
                            <.link patch={dashboard_path(@filters, entry.issue.identifier, :index)} style={action_link_style()}>Inspect run</.link>
                            <.link navigate={dashboard_path(@filters, entry.issue.identifier, :show)} style={action_link_style()}>Open full page</.link>
                          </div>
                        </div>

                        <details style={details_style()}>
                          <summary style={summary_style()}>Run details</summary>
                          <dl style={detail_grid_style()}>
                            <div>
                              <dt style={dt_style()}>Started</dt>
                              <dd style={dd_style()}>{format_timestamp(entry.started_at)}</dd>
                            </div>
                            <div>
                              <dt style={dt_style()}>Completed</dt>
                              <dd style={dd_style()}>{format_timestamp(entry.completed_at)}</dd>
                            </div>
                            <div>
                              <dt style={dt_style()}>Thread</dt>
                              <dd style={dd_style()}>{present(entry.thread_id)}</dd>
                            </div>
                            <div>
                              <dt style={dt_style()}>Session</dt>
                              <dd style={dd_style()}>{present(entry.session_id)}</dd>
                            </div>
                            <div>
                              <dt style={dt_style()}>Turn</dt>
                              <dd style={dd_style()}>{present(entry.turn_id)}</dd>
                            </div>
                            <div>
                              <dt style={dt_style()}>Recovered runs</dt>
                              <dd style={dd_style()}>{entry.recovery_count}</dd>
                            </div>
                            <div>
                              <dt style={dt_style()}>Last event</dt>
                              <dd style={dd_style()}>{present(entry.last_event)}</dd>
                            </div>
                            <div>
                              <dt style={dt_style()}>Error category</dt>
                              <dd style={dd_style()}>{present(entry.error_category)}</dd>
                            </div>
                            <%= if entry.workspace_path do %>
                              <div style="grid-column: 1 / -1;">
                                <dt style={dt_style()}>Workspace</dt>
                                <dd style={dd_style()}><code>{entry.workspace_path}</code></dd>
                              </div>
                            <% end %>
                            <div style="grid-column: 1 / -1;">
                              <dt style={dt_style()}>Outcome details</dt>
                              <dd style={dd_style()}>{present(entry.last_message || entry.error)}</dd>
                            </div>
                          </dl>

                          <%= if entry.log_excerpt.exists do %>
                            <div style="margin-top: 14px; padding-top: 12px; border-top: 1px dashed #d1d5db;">
                              <div style="display: flex; justify-content: space-between; gap: 12px; align-items: baseline; flex-wrap: wrap; margin-bottom: 8px;">
                                <strong style="font-size: 14px; color: #111827;">NDJSON breadcrumb tail</strong>
                                <span style="font-size: 12px; color: #6b7280;">{entry.log_excerpt.event_count} event(s) · {entry.log_excerpt.path}</span>
                              </div>
                              <div style="display: grid; gap: 8px;">
                                <%= for event <- entry.log_excerpt.recent_events do %>
                                  <div style="border: 1px solid #e5e7eb; border-radius: 10px; padding: 10px; background: #fff;">
                                    <div style="display: flex; gap: 8px; flex-wrap: wrap; align-items: center; margin-bottom: 4px;">
                                      <span style={pill_style(:neutral)}>{present(event.event)}</span>
                                      <span style="font-size: 12px; color: #6b7280;">{format_timestamp(event.timestamp)}</span>
                                      <%= if present?(event.status) do %>
                                        <span style={pill_style(:info)}>{event.status}</span>
                                      <% end %>
                                    </div>
                                    <div style="font-size: 13px; color: #374151; line-height: 1.4;">{present(event.message)}</div>
                                    <%= if present?(event.raw_method) do %>
                                      <div style="font-size: 12px; color: #6b7280; margin-top: 4px;">{event.raw_method}</div>
                                    <% end %>
                                  </div>
                                <% end %>
                              </div>
                            </div>
                          <% end %>
                        </details>
                      </article>
                    <% end %>
                  </div>
                <% end %>
              </section>
            <% end %>
          </div>

          <div class="dashboard-sidebar">
            <section style={panel_style()}>
              <%= if @selected_run do %>
                <.run_detail_panel run={@selected_run} filters={@filters} detail_mode={:sidebar} />
              <% else %>
                <div>
                  <h2 style="margin-top: 0; font-size: 20px;">Run inspector</h2>
                  <p style="margin: 8px 0 0; color: #6b7280; line-height: 1.5;">
                    Pick any running, retry-queued, or completed issue to inspect its workspace breadcrumbs,
                    session snapshot, debug directory, and fuller NDJSON event timeline.
                  </p>
                </div>
              <% end %>
            </section>

            <section style={panel_style()}>
              <h2 style="margin-top: 0; font-size: 20px;">Orchestrator settings</h2>
              <dl style="display: grid; grid-template-columns: minmax(0, 1fr); gap: 10px; margin: 0;">
                <%= for {label, value} <- settings_rows(@snapshot.settings) do %>
                  <div>
                    <dt style={dt_style()}>{label}</dt>
                    <dd style={dd_style()}>{value}</dd>
                  </div>
                <% end %>
              </dl>
            </section>

            <section style={panel_style()}>
              <h2 style="margin-top: 0; font-size: 20px;">Runtime controls</h2>
              <p style="margin: 8px 0 12px; color: #6b7280; line-height: 1.5;">
                Update the `orchestrator` block in `WORKFLOW.md`, reload it into the live runtime,
                or restart bounded runtime components from this dashboard.
              </p>

              <.form for={%{}} as={:runtime} phx-submit="save_runtime_settings" style="display: grid; gap: 10px;">
                <label style={field_label_style()}>
                  Poll interval (ms)
                  <input type="number" min="1" name="runtime[poll_interval_ms]" value={@snapshot.settings.poll_interval_ms} style={input_style()} />
                </label>

                <label style={field_label_style()}>
                  Max concurrent
                  <input type="number" min="1" name="runtime[max_concurrent]" value={@snapshot.settings.max_concurrent} style={input_style()} />
                </label>

                <label style={field_label_style()}>
                  Max retries
                  <input type="number" min="0" name="runtime[max_retries]" value={@snapshot.settings.max_retries} style={input_style()} />
                </label>

                <label style={field_label_style()}>
                  Retry backoff base (ms)
                  <input type="number" min="1" name="runtime[backoff_base_ms]" value={@snapshot.settings.retry_backoff_ms} style={input_style()} />
                </label>

                <button type="submit" style={primary_button_style()}>Save settings & reload</button>
              </.form>

              <div style="display: grid; gap: 8px; margin-top: 14px;">
                <button type="button" phx-click="restart_component" phx-value-component="orchestrator" style={secondary_button_style()}>
                  Restart orchestrator
                </button>
                <button type="button" phx-click="restart_component" phx-value-component="endpoint" style={secondary_button_style()}>
                  Restart dashboard endpoint
                </button>
              </div>
            </section>

            <section style={panel_style()}>
              <h2 style="margin-top: 0; font-size: 20px;">Recent tracker write-back</h2>
              <.write_back_stage_list entries={@snapshot.write_back_stages.recent} empty_message="No tracker write-back activity has been recorded yet." />
            </section>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  attr(:run, :map, required: true)
  attr(:filters, :map, required: true)
  attr(:detail_mode, :atom, default: :sidebar)

  defp run_detail_panel(assigns) do
    ~H"""
    <div>
      <div style="display: flex; justify-content: space-between; gap: 12px; align-items: start; flex-wrap: wrap; margin-bottom: 14px;">
        <div>
          <div style="font-size: 12px; color: #6b7280; text-transform: uppercase;">
            <%= if @detail_mode == :full_page, do: "Run detail", else: "Run inspector" %>
          </div>
          <h2 style="margin: 4px 0 6px; font-size: 22px;">{@run.issue.identifier}</h2>
          <div style="color: #374151; line-height: 1.5;">{@run.issue.title}</div>
        </div>
        <div style="display: flex; gap: 8px; flex-wrap: wrap; justify-content: flex-end; align-items: center;">
          <span style={pill_style(queue_tone(@run.queue))}>{humanize_queue(@run.queue)}</span>
          <span style={pill_style(:neutral)}>{present(Map.get(@run, :concurrency_class))}</span>
          <%= if @detail_mode == :sidebar do %>
            <.link navigate={dashboard_path(@filters, @run.issue.identifier, :show)} style={action_link_style()}>Open full page</.link>
          <% end %>
          <%= if @detail_mode == :full_page do %>
            <.link navigate={dashboard_path(@filters, @run.issue.identifier, :index)} style={action_link_style()}>Open split view</.link>
          <% end %>
        </div>
      </div>

      <dl style={detail_grid_style()}>
        <div>
          <dt style={dt_style()}>Attempt</dt>
          <dd style={dd_style()}>{@run.attempt}</dd>
        </div>
        <div>
          <dt style={dt_style()}>Result / state</dt>
          <dd style={dd_style()}>{present(@run[:result] || @run[:state] || get_in(@run, [:last_result, :status]))}</dd>
        </div>
        <div>
          <dt style={dt_style()}>Thread</dt>
          <dd style={dd_style()}>{present(@run[:thread_id] || get_in(@run, [:session_excerpt, :data, :thread_id]) || get_in(@run, [:last_result, :thread_id]))}</dd>
        </div>
        <div>
          <dt style={dt_style()}>Session</dt>
          <dd style={dd_style()}>{present(@run[:session_id] || get_in(@run, [:session_excerpt, :data, :session_id]) || get_in(@run, [:last_result, :session_id]))}</dd>
        </div>
        <div>
          <dt style={dt_style()}>Turn</dt>
          <dd style={dd_style()}>{present(@run[:turn_id] || get_in(@run, [:session_excerpt, :data, :turn_id]) || get_in(@run, [:last_result, :turn_id]))}</dd>
        </div>
        <div>
          <dt style={dt_style()}>Recovery count</dt>
          <dd style={dd_style()}>{@run[:recovery_count] || get_in(@run, [:session_excerpt, :data, :recovery_count]) || get_in(@run, [:last_result, :recovery_count]) || 0}</dd>
        </div>
        <div>
          <dt style={dt_style()}>Workspace</dt>
          <dd style={dd_style()}><code>{present(get_in(@run, [:paths, :workspace]))}</code></dd>
        </div>
        <div>
          <dt style={dt_style()}>Conflict keys</dt>
          <dd style={dd_style()}>{joined(@run[:conflict_keys] || [])}</dd>
        </div>
        <div style="grid-column: 1 / -1;">
          <dt style={dt_style()}>Last message</dt>
          <dd style={dd_style()}>{present(@run[:last_message] || @run[:error] || get_in(@run, [:last_result, :last_message]) || get_in(@run, [:last_result, :error]))}</dd>
        </div>
      </dl>

      <div style="margin-top: 16px; display: grid; gap: 12px;">
        <section style={subpanel_style()}>
          <div style="font-size: 14px; font-weight: 700; margin-bottom: 8px;">Breadcrumb files</div>
          <dl style="display: grid; gap: 8px; margin: 0;">
            <div>
              <dt style={dt_style()}>Session breadcrumb</dt>
              <dd style={dd_style()}><code>{present(get_in(@run, [:paths, :session]))}</code></dd>
            </div>
            <div>
              <dt style={dt_style()}>Run NDJSON</dt>
              <dd style={dd_style()}><code>{present(get_in(@run, [:paths, :events]))}</code></dd>
            </div>
            <div>
              <dt style={dt_style()}>Debug directory</dt>
              <dd style={dd_style()}><code>{present(get_in(@run, [:paths, :debug_dir]))}</code></dd>
            </div>
          </dl>
        </section>

        <section style={subpanel_style()}>
          <div style="display: flex; justify-content: space-between; gap: 12px; align-items: baseline; flex-wrap: wrap; margin-bottom: 8px;">
            <div style="font-size: 14px; font-weight: 700;">Session snapshot</div>
            <span style="font-size: 12px; color: #6b7280;">
              <%= if @run.session_excerpt.exists do %>found<% else %>missing<% end %>
            </span>
          </div>
          <%= if @run.session_excerpt.exists do %>
            <dl style="display: grid; gap: 8px; margin: 0;">
              <%= for {label, value} <- session_rows(@run.session_excerpt.data) do %>
                <div>
                  <dt style={dt_style()}>{label}</dt>
                  <dd style={dd_style()}>{value}</dd>
                </div>
              <% end %>
            </dl>
          <% else %>
            <p style="margin: 0; color: #6b7280;">No `.symphony-session.json` breadcrumb is currently available for this workspace.</p>
          <% end %>
        </section>

        <section style={subpanel_style()}>
          <div style="display: flex; justify-content: space-between; gap: 12px; align-items: baseline; flex-wrap: wrap; margin-bottom: 8px;">
            <div style="font-size: 14px; font-weight: 700;">Debug artifacts</div>
            <span style="font-size: 12px; color: #6b7280;">
              <%= if @run.debug_excerpt.exists do %>{length(@run.debug_excerpt.files)} file(s)<% else %>none found<% end %>
            </span>
          </div>
          <%= if @run.debug_excerpt.exists && @run.debug_excerpt.files != [] do %>
            <ul style="margin: 0; padding-left: 18px; color: #374151; display: grid; gap: 6px;">
              <%= for file <- @run.debug_excerpt.files do %>
                <li><code>{file}</code></li>
              <% end %>
            </ul>
          <% else %>
            <p style="margin: 0; color: #6b7280;">No `.symphony/debug` artifacts were discovered for this run yet.</p>
          <% end %>
        </section>

        <section style={subpanel_style()}>
          <div style="display: flex; justify-content: space-between; gap: 12px; align-items: baseline; flex-wrap: wrap; margin-bottom: 8px;">
            <div style="font-size: 14px; font-weight: 700;">GitHub write-back</div>
            <span style="font-size: 12px; color: #6b7280;">{length(@run.write_back_stages)} stage event(s)</span>
          </div>
          <.write_back_stage_list entries={@run.write_back_stages} empty_message="No tracker write-back stages have been recorded for this run yet." />
        </section>

        <section style={subpanel_style()}>
          <div style="display: flex; justify-content: space-between; gap: 12px; align-items: baseline; flex-wrap: wrap; margin-bottom: 8px;">
            <div style="font-size: 14px; font-weight: 700;">Event timeline</div>
            <span style="font-size: 12px; color: #6b7280;">last {length(@run.log_timeline.recent_events)} of {@run.log_timeline.event_count} event(s)</span>
          </div>
          <%= if @run.log_timeline.exists do %>
            <div style={timeline_container_style(@detail_mode)}>
              <%= for event <- @run.log_timeline.recent_events do %>
                <div style="border: 1px solid #e5e7eb; border-radius: 10px; padding: 10px; background: #fff;">
                  <div style="display: flex; gap: 8px; flex-wrap: wrap; align-items: center; margin-bottom: 4px;">
                    <span style={pill_style(:neutral)}>{present(event.event)}</span>
                    <span style="font-size: 12px; color: #6b7280;">{format_timestamp(event.timestamp)}</span>
                    <%= if present?(event.status) do %>
                      <span style={pill_style(:info)}>{event.status}</span>
                    <% end %>
                  </div>
                  <div style="font-size: 13px; color: #374151; line-height: 1.45;">{present(event.message)}</div>
                  <%= if present?(event.raw_method) do %>
                    <div style="font-size: 12px; color: #6b7280; margin-top: 4px;">{event.raw_method}</div>
                  <% end %>
                </div>
              <% end %>
            </div>
          <% else %>
            <p style="margin: 0; color: #6b7280;">No NDJSON events were found for this run yet.</p>
          <% end %>
        </section>
      </div>
    </div>
    """
  end

  attr(:entries, :list, required: true)
  attr(:empty_message, :string, required: true)

  defp write_back_stage_list(assigns) do
    ~H"""
    <%= if @entries == [] do %>
      <p style="margin: 0; color: #6b7280;">{@empty_message}</p>
    <% else %>
      <div style="display: grid; gap: 8px;">
        <%= for entry <- @entries do %>
          <div style="border: 1px solid #e5e7eb; border-radius: 10px; padding: 10px; background: #fff;">
            <div style="display: flex; gap: 8px; flex-wrap: wrap; align-items: center; margin-bottom: 4px;">
              <span style={pill_style(:neutral)}>{entry.issue_identifier}</span>
              <span style={pill_style(write_back_tone(entry.outcome))}>{entry.outcome}</span>
              <span style={pill_style(:info)}>{entry.stage}</span>
              <%= if present?(entry.failed_stage) do %>
                <span style={pill_style(:retry)}>failed {entry.failed_stage}</span>
              <% end %>
              <span style="font-size: 12px; color: #6b7280;">{format_timestamp(entry.captured_at)}</span>
            </div>
            <div style="font-size: 13px; color: #374151; line-height: 1.45;">
              <strong>{entry.tracker_kind}</strong>
              <%= if present?(entry.status) do %>
                · status {entry.status}
              <% end %>
              <%= if present?(entry.reason) do %>
                · {entry.reason}
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp current_snapshot do
    RuntimeSnapshot.from_orchestrator(orchestrator_server())
  end

  defp assign_snapshot(socket, snapshot) do
    filters = socket.assigns[:filters] || @default_filters
    selected_identifier = socket.assigns[:selected_identifier]

    assign(socket,
      snapshot: snapshot,
      view: %{
        running:
          snapshot.running
          |> filter_entries(filters, :running)
          |> sort_active_entries(filters, :running),
        retry_queue:
          snapshot.retry_queue
          |> filter_entries(filters, :retry_queue)
          |> sort_active_entries(filters, :retry_queue),
        completed:
          snapshot.completed
          |> filter_entries(filters, :completed)
          |> filter_completed_window(filters["completed_window"])
          |> sort_completed(filters["completed_sort"])
      },
      selected_run: selected_run(snapshot, selected_identifier)
    )
  end

  defp selected_run(_snapshot, nil), do: nil
  defp selected_run(snapshot, identifier), do: RuntimeSnapshot.run_detail(snapshot, identifier)

  defp orchestrator_server do
    Application.get_env(:symphony_ex, :dashboard_orchestrator, SymphonyEx.Orchestrator)
  end

  defp default_filters, do: @default_filters

  defp component_from_param("orchestrator"), do: {:ok, :orchestrator}
  defp component_from_param("endpoint"), do: {:ok, :endpoint}
  defp component_from_param(_other), do: :error

  defp normalize_filters(params) do
    error_category = normalize_error_category(params)

    %{
      "q" => params |> Map.get("q", "") |> to_string() |> String.trim(),
      "queue" => normalize_queue(Map.get(params, "queue", "all")),
      "class" => normalize_class(Map.get(params, "class", "all")),
      "result" => normalize_result(Map.get(params, "result", "all")),
      "status" => normalize_status(Map.get(params, "status", "all")),
      "error_category" => error_category,
      "active_sort" => normalize_active_sort(Map.get(params, "active_sort", "default")),
      "completed_sort" => normalize_completed_sort(Map.get(params, "completed_sort", "newest")),
      "completed_window" =>
        normalize_completed_window(Map.get(params, "completed_window", "all")),
      "completed_limit" => normalize_completed_limit(Map.get(params, "completed_limit", "10"))
    }
  end

  defp normalize_queue(queue) when queue in ["all", "running", "retry_queue", "completed"],
    do: queue

  defp normalize_queue(_queue), do: "all"

  defp normalize_class(class) when class in ["all", "code", "docs", "infra", "other"], do: class
  defp normalize_class(_class), do: "all"

  defp normalize_result(result) when result in ["all", "success", "failed", "cancelled"],
    do: result

  defp normalize_result(_result), do: "all"

  defp normalize_status(status) when status in ["all", "success", "failed", "cancelled"],
    do: status

  defp normalize_status(_status), do: "all"

  defp normalize_active_sort(sort)
       when sort in ["default", "oldest", "longest", "priority_desc", "identifier_asc"],
       do: sort

  defp normalize_active_sort(_sort), do: "default"

  defp normalize_completed_sort(sort)
       when sort in [
              "newest",
              "oldest",
              "runtime_desc",
              "runtime_asc",
              "identifier_asc",
              "priority_desc"
            ],
       do: sort

  defp normalize_completed_sort(_sort), do: "newest"

  defp normalize_completed_window(window) when window in ["all", "24h", "3d", "7d"], do: window
  defp normalize_completed_window(_window), do: "all"

  defp normalize_completed_limit(limit) when limit in ["10", "25", "50", "100"], do: limit
  defp normalize_completed_limit(_limit), do: "10"

  defp normalize_error_category(params) do
    custom = params |> Map.get("error_category_custom", "") |> to_string() |> String.trim()

    case params |> Map.get("error_category", "") |> to_string() |> String.trim() do
      "__custom__" -> custom
      value -> value
    end
  end

  defp normalize_identifier(nil), do: nil
  defp normalize_identifier(""), do: nil
  defp normalize_identifier(identifier), do: to_string(identifier)

  defp dashboard_path(filters, selected_identifier, live_action)

  defp dashboard_path(filters, nil, :show), do: dashboard_path(filters, nil, :index)

  defp dashboard_path(filters, selected_identifier, live_action) do
    params =
      filters
      |> Enum.reject(fn {_key, value} -> value in [nil, "", "all", "default"] end)
      |> Enum.into(%{})

    case live_action do
      :show -> ~p"/runs/#{selected_identifier}?#{params}"
      _other -> ~p"/?#{maybe_put(params, "run", selected_identifier)}"
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp page_title(:show, nil), do: "Run Detail · Symphony Dashboard"
  defp page_title(:show, identifier), do: "#{identifier} · Symphony Dashboard"
  defp page_title(_action, _identifier), do: "Symphony Dashboard"

  defp flash_message(flash, kind), do: Phoenix.Flash.get(flash, kind)

  defp queue_visible?(filters, queue), do: filters["queue"] in ["all", queue]

  defp active_filters?(filters), do: filters != @default_filters

  defp empty_message(filters, queue, default) do
    cond do
      filters["queue"] not in ["all", queue] -> ""
      active_filters?(filters) -> "No matching issues for the current filters."
      true -> default
    end
  end

  defp filter_entries(entries, filters, queue) do
    query = String.downcase(filters["q"] || "")

    Enum.filter(entries, fn entry ->
      matches_query_filter?(entry, query) and
        matches_class_filter?(entry, filters["class"]) and
        matches_result_filter?(entry, filters["result"], queue) and
        matches_status_filter?(entry, filters["status"], queue) and
        matches_error_category_filter?(entry, filters["error_category"], queue)
    end)
  end

  defp matches_query_filter?(_entry, ""), do: true

  defp matches_query_filter?(entry, query) do
    issue = entry[:issue]

    haystack =
      [
        issue_field(issue, :identifier),
        issue_field(issue, :title),
        issue_field(issue, :state),
        joined(issue_field(issue, :labels) || []),
        joined(issue_field(issue, :assignees) || []),
        joined(issue_field(issue, :conflict_hints) || []),
        joined(Map.get(entry, :conflict_keys, [])),
        Map.get(entry, :workspace_path),
        Map.get(entry, :last_event),
        Map.get(entry, :last_message),
        Map.get(entry, :error),
        Map.get(entry, :thread_id),
        Map.get(entry, :session_id),
        Map.get(entry, :concurrency_class),
        Map.get(entry, :result),
        Map.get(entry, :error_category),
        get_in(entry, [:last_result, :status]),
        get_in(entry, [:last_result, :error_category]),
        get_in(entry, [:last_result, :thread_id]),
        get_in(entry, [:last_result, :session_id])
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    String.contains?(haystack, query)
  end

  defp matches_class_filter?(_entry, "all"), do: true

  defp matches_class_filter?(entry, "other"),
    do: to_string(entry[:concurrency_class] || "other") not in ["code", "docs", "infra"]

  defp matches_class_filter?(entry, class), do: to_string(entry[:concurrency_class]) == class

  defp matches_result_filter?(_entry, "all", _queue), do: true
  defp matches_result_filter?(_entry, _result, queue) when queue != :completed, do: true

  defp matches_result_filter?(entry, result, :completed),
    do: Atom.to_string(entry.result) == result

  defp matches_status_filter?(_entry, "all", _queue), do: true
  defp matches_status_filter?(_entry, _status, :running), do: true

  defp matches_status_filter?(entry, status, :retry_queue),
    do: to_string(get_in(entry, [:last_result, :status])) == status

  defp matches_status_filter?(entry, status, :completed),
    do: Atom.to_string(entry.result) == status

  defp matches_error_category_filter?(_entry, "", _queue), do: true
  defp matches_error_category_filter?(_entry, _category, :running), do: true

  defp matches_error_category_filter?(entry, category, :retry_queue),
    do:
      String.contains?(
        String.downcase(to_string(get_in(entry, [:last_result, :error_category]))),
        String.downcase(category)
      )

  defp matches_error_category_filter?(entry, category, :completed),
    do:
      String.contains?(
        String.downcase(to_string(entry.error_category)),
        String.downcase(category)
      )

  defp filter_completed_window(entries, "all"), do: entries

  defp filter_completed_window(entries, window) do
    now = DateTime.utc_now()
    cutoff_seconds = completed_window_seconds(window)

    Enum.filter(entries, fn entry ->
      case DateTime.from_iso8601(to_string(entry.completed_at)) do
        {:ok, completed_at, _offset} ->
          DateTime.diff(now, completed_at, :second) <= cutoff_seconds

        _ ->
          false
      end
    end)
  end

  defp completed_window_seconds("24h"), do: 24 * 60 * 60
  defp completed_window_seconds("3d"), do: 3 * 24 * 60 * 60
  defp completed_window_seconds("7d"), do: 7 * 24 * 60 * 60

  defp sort_active_entries(entries, %{"active_sort" => "oldest"}, :running) do
    Enum.sort_by(entries, &{started_sort_key(&1), &1.issue.identifier}, :asc)
  end

  defp sort_active_entries(entries, %{"active_sort" => "oldest"}, :retry_queue) do
    Enum.sort_by(entries, &{queued_sort_key(&1), &1.issue.identifier}, :asc)
  end

  defp sort_active_entries(entries, %{"active_sort" => "longest"}, :running) do
    Enum.sort_by(entries, &{-(&1.elapsed_ms || -1), &1.issue.identifier})
  end

  defp sort_active_entries(entries, %{"active_sort" => "longest"}, :retry_queue) do
    Enum.sort_by(entries, &{-(&1.queued_for_ms || -1), &1.issue.identifier})
  end

  defp sort_active_entries(entries, %{"active_sort" => "priority_desc"}, _queue) do
    Enum.sort_by(entries, &{-priority_value(&1), &1.issue.identifier})
  end

  defp sort_active_entries(entries, %{"active_sort" => "identifier_asc"}, _queue) do
    Enum.sort_by(entries, & &1.issue.identifier, :asc)
  end

  defp sort_active_entries(entries, _filters, _queue), do: entries

  defp sort_completed(entries, "oldest") do
    Enum.sort_by(entries, &completed_sort_key/1, :asc)
  end

  defp sort_completed(entries, "runtime_desc") do
    Enum.sort_by(entries, &{-(&1.elapsed_ms || -1), &1.issue.identifier})
  end

  defp sort_completed(entries, "runtime_asc") do
    Enum.sort_by(entries, &{&1.elapsed_ms || 9_999_999_999, &1.issue.identifier})
  end

  defp sort_completed(entries, "identifier_asc") do
    Enum.sort_by(entries, & &1.issue.identifier, :asc)
  end

  defp sort_completed(entries, "priority_desc") do
    Enum.sort_by(entries, &{-priority_value(&1), &1.issue.identifier})
  end

  defp sort_completed(entries, _sort) do
    Enum.sort_by(entries, &completed_sort_key/1, :desc)
  end

  defp started_sort_key(entry), do: iso8601_sort_key(entry.started_at)
  defp queued_sort_key(entry), do: iso8601_sort_key(entry.queued_at)
  defp completed_sort_key(entry), do: iso8601_sort_key(entry.completed_at)

  defp iso8601_sort_key(nil), do: 0

  defp iso8601_sort_key(value) do
    case DateTime.from_iso8601(to_string(value)) do
      {:ok, dt, _offset} -> DateTime.to_unix(dt, :microsecond)
      _ -> value
    end
  end

  defp priority_value(entry), do: issue_field(entry[:issue], :priority) || 0

  defp issue_field(nil, _key), do: nil
  defp issue_field(issue, key), do: Map.get(issue, key)

  defp completed_limit(filters), do: String.to_integer(filters["completed_limit"] || "10")

  defp view_total_count(view),
    do: length(view.running) + length(view.retry_queue) + length(view.completed)

  defp active_filter_chips(filters) do
    [
      filter_chip(filters["q"], &(&1 != ""), &"search: #{&1}"),
      filter_chip(filters["queue"], &(&1 != "all"), &"queue: #{humanize_filter_value(&1)}"),
      filter_chip(filters["class"], &(&1 != "all"), &"class: #{humanize_filter_value(&1)}"),
      filter_chip(filters["result"], &(&1 != "all"), &"outcome: #{humanize_filter_value(&1)}"),
      filter_chip(filters["status"], &(&1 != "all"), &"status: #{humanize_filter_value(&1)}"),
      filter_chip(filters["error_category"], &(&1 != ""), &"error: #{&1}"),
      filter_chip(
        filters["active_sort"],
        &(&1 != "default"),
        &"active sort: #{humanize_filter_value(&1)}"
      ),
      filter_chip(
        filters["completed_sort"],
        &(&1 != "newest"),
        &"completed sort: #{humanize_filter_value(&1)}"
      ),
      filter_chip(
        filters["completed_window"],
        &(&1 != "all"),
        &"history: #{humanize_filter_value(&1)}"
      ),
      filter_chip(filters["completed_limit"], &(&1 != "10"), &"rows: #{&1}")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp filter_chip(value, predicate, render) do
    if predicate.(value), do: render.(value), else: nil
  end

  defp selected_error_category?(filters, "") do
    filters["error_category"] in [nil, ""]
  end

  defp selected_error_category?(filters, "__custom__") do
    custom_error_category?(filters)
  end

  defp selected_error_category?(filters, value) do
    filters["error_category"] == value
  end

  defp custom_error_category?(filters) do
    value = filters["error_category"] || ""
    value != "" and value not in Enum.map(@error_category_options, &elem(&1, 1))
  end

  defp custom_error_category_value(filters) do
    if custom_error_category?(filters), do: filters["error_category"], else: ""
  end

  defp humanize_filter_value("retry_queue"), do: "retry queue"
  defp humanize_filter_value("priority_desc"), do: "priority ↓"
  defp humanize_filter_value("identifier_asc"), do: "identifier A→Z"
  defp humanize_filter_value("runtime_desc"), do: "runtime ↓"
  defp humanize_filter_value("runtime_asc"), do: "runtime ↑"
  defp humanize_filter_value("24h"), do: "24h"
  defp humanize_filter_value("3d"), do: "3 days"
  defp humanize_filter_value("7d"), do: "7 days"
  defp humanize_filter_value(value), do: String.replace(to_string(value), "_", " ")

  defp summary_cards(summary) do
    rate_limits = Map.get(summary, :rate_limits, %{})

    [
      %{label: "Running", value: summary.running_count},
      %{label: "Retry queued", value: summary.retry_queue_count},
      %{label: "Completed", value: summary.completed_count},
      %{label: "Success rate", value: percentage_label(summary[:success_rate])},
      %{label: "Avg runtime", value: format_duration(summary[:average_runtime_ms])},
      %{label: "Open slots", value: summary.available_slots},
      %{label: "Max concurrent", value: summary.max_concurrent},
      %{label: "Write-back alerts", value: summary[:write_back_alert_count] || 0},
      %{label: "GitHub rate limit", value: rate_limit_label(rate_limits[:github])}
    ]
  end

  defp settings_rows(settings) do
    [
      {"Poll interval (ms)", settings.poll_interval_ms},
      {"Candidate poll interval (ms)", settings[:candidate_poll_interval_ms]},
      {"Candidate poll backoff until", settings[:candidate_poll_backoff_until] || "—"},
      {"Max concurrent", settings.max_concurrent},
      {"Max retries", settings.max_retries},
      {"Retry backoff base (ms)", settings.retry_backoff_ms},
      {"Retry backoff max (ms)", settings.max_retry_backoff_ms},
      {"Concurrency limits", inspect(settings.concurrency_limits)},
      {"Blocked labels", joined(settings.blocked_labels)},
      {"Serialization prefixes", joined(settings.serialization_label_prefixes)},
      {"Explicit issue", settings.explicit_issue_identifier || "—"},
      {"Workflow path", settings.workflow_path || "—"}
    ]
  end

  defp runtime_control_error({:invalid_setting, field, min}) do
    "#{humanize_runtime_field(field)} must be an integer greater than or equal to #{min}."
  end

  defp runtime_control_error({:component_not_running, component}) do
    "#{humanize_component(component)} is not running."
  end

  defp runtime_control_error(:workflow_path_unavailable),
    do: "Runtime workflow path is unavailable."

  defp runtime_control_error(%ArgumentError{} = error), do: Exception.message(error)
  defp runtime_control_error(%RuntimeError{} = error), do: Exception.message(error)
  defp runtime_control_error(reason), do: "Runtime control failed: #{inspect(reason)}"

  defp humanize_runtime_field(:poll_interval_ms), do: "Poll interval"
  defp humanize_runtime_field(:max_concurrent), do: "Max concurrent"
  defp humanize_runtime_field(:max_retries), do: "Max retries"
  defp humanize_runtime_field(:backoff_base_ms), do: "Retry backoff base"
  defp humanize_runtime_field(field), do: to_string(field)

  defp humanize_component(:orchestrator), do: "Orchestrator"
  defp humanize_component(:endpoint), do: "Dashboard endpoint"
  defp humanize_component(component), do: to_string(component)

  defp session_rows(nil), do: []

  defp session_rows(data) do
    [
      {"Phase", present(data.phase)},
      {"Updated", format_timestamp(data.updated_at)},
      {"Thread", present(data.thread_id)},
      {"Session", present(data.session_id)},
      {"Turn", present(data.turn_id)},
      {"Last event", present(data.last_event)},
      {"Turns executed", data.turns_executed || 0},
      {"Recovery count", data.recovery_count || 0},
      {"Error category", present(data.error_category)},
      {"Error", present(data.error)},
      {"Capabilities", inspect(data.capability_profile || %{})}
    ]
  end

  defp joined([]), do: "—"
  defp joined(values), do: Enum.join(values, ", ")

  defp completed_tone(:success), do: :success
  defp completed_tone(:cancelled), do: :retry
  defp completed_tone(_other), do: :danger

  defp write_back_tone("success"), do: :success
  defp write_back_tone("partial"), do: :retry
  defp write_back_tone("failed"), do: :danger
  defp write_back_tone(_other), do: :neutral

  defp queue_tone(:running), do: :running
  defp queue_tone(:retry_queue), do: :retry
  defp queue_tone(:completed), do: :success
  defp queue_tone(_other), do: :neutral

  defp humanize_queue(:retry_queue), do: "retry queue"
  defp humanize_queue(queue), do: to_string(queue)

  defp percentage_label(nil), do: "—"
  defp percentage_label(value), do: "#{value}%"

  defp rate_limit_label(nil), do: "—"

  defp rate_limit_label(snapshot) do
    remaining = snapshot[:remaining]
    limit = snapshot[:limit]

    cond do
      is_integer(remaining) and is_integer(limit) -> "#{remaining}/#{limit}"
      is_integer(remaining) -> Integer.to_string(remaining)
      true -> "—"
    end
  end

  defp format_duration(nil), do: "—"
  defp format_duration(ms) when ms < 1_000, do: "#{ms} ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1_000, 1)} s"
  defp format_duration(ms) when ms < 3_600_000, do: "#{Float.round(ms / 60_000, 1)} min"
  defp format_duration(ms), do: "#{Float.round(ms / 3_600_000, 1)} hr"

  defp present_duration(nil), do: "—"
  defp present_duration(ms), do: format_duration(ms)

  defp format_timestamp(nil), do: "—"

  defp format_timestamp(value) do
    case DateTime.from_iso8601(to_string(value)) do
      {:ok, dt, _offset} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
      _ -> to_string(value)
    end
  end

  defp present(nil), do: "—"
  defp present(""), do: "—"
  defp present(value) when is_atom(value), do: Atom.to_string(value)
  defp present(value), do: to_string(value)

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?("—"), do: false
  defp present?(_value), do: true

  defp panel_style do
    "border: 1px solid #e5e7eb; border-radius: 14px; padding: 16px; background: white; box-shadow: 0 1px 2px rgba(15, 23, 42, 0.04);"
  end

  defp subpanel_style do
    "border: 1px solid #e5e7eb; border-radius: 12px; padding: 12px; background: #fcfcfd;"
  end

  defp entry_card_style(entry, selected_identifier, extra \\ "") do
    selected? = issue_field(entry[:issue], :identifier) == selected_identifier

    border =
      if selected?,
        do: "border: 1px solid #2563eb; box-shadow: inset 0 0 0 1px rgba(37, 99, 235, 0.12);",
        else: "border: 1px solid #e5e7eb;"

    "#{border} border-radius: 12px; padding: 14px; background: #fcfcfd; #{extra}"
  end

  defp details_style do
    "margin-top: 12px; border-top: 1px solid #e5e7eb; padding-top: 12px;"
  end

  defp summary_style do
    "cursor: pointer; font-weight: 600; color: #374151;"
  end

  defp detail_grid_style do
    "display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 10px 12px; margin: 0;"
  end

  defp timeline_container_style(:full_page) do
    "display: grid; gap: 8px; max-height: none; overflow: visible;"
  end

  defp timeline_container_style(_mode) do
    "display: grid; gap: 8px; max-height: 640px; overflow: auto; padding-right: 4px;"
  end

  defp field_label_style do
    "display: grid; gap: 6px; font-size: 13px; color: #4b5563;"
  end

  defp muted_text_style do
    "margin: 4px 0 0; color: #6b7280; font-size: 13px; line-height: 1.5;"
  end

  defp input_style do
    "border: 1px solid #d1d5db; border-radius: 10px; padding: 10px 12px; font: inherit; background: #fff; color: #111827; width: 100%;"
  end

  defp action_link_style do
    "font-size: 12px; font-weight: 600; color: #2563eb; text-decoration: none;"
  end

  defp flash_style(:info) do
    "margin-bottom: 16px; padding: 12px 14px; border-radius: 12px; border: 1px solid #bfdbfe; background: #eff6ff; color: #1d4ed8;"
  end

  defp flash_style(:error) do
    "margin-bottom: 16px; padding: 12px 14px; border-radius: 12px; border: 1px solid #fecaca; background: #fef2f2; color: #b91c1c;"
  end

  defp primary_button_style do
    "appearance: none; border: 0; border-radius: 10px; padding: 10px 14px; background: #111827; color: white; font-weight: 600; cursor: pointer;"
  end

  defp secondary_button_style do
    "appearance: none; border: 1px solid #d1d5db; border-radius: 10px; padding: 10px 14px; background: white; color: #111827; font-weight: 600; cursor: pointer; text-align: left;"
  end

  defp dt_style, do: "font-size: 12px; color: #6b7280;"
  defp dd_style, do: "margin: 0; word-break: break-word;"

  defp pill_style(:running), do: pill_style("#dbeafe", "#1d4ed8")
  defp pill_style(:retry), do: pill_style("#fef3c7", "#92400e")
  defp pill_style(:success), do: pill_style("#dcfce7", "#166534")
  defp pill_style(:danger), do: pill_style("#fee2e2", "#991b1b")
  defp pill_style(:info), do: pill_style("#e0f2fe", "#0369a1")
  defp pill_style(:neutral), do: pill_style("#e5e7eb", "#374151")

  defp pill_style(background, color) do
    "display:inline-flex;align-items:center;border-radius:999px;padding:4px 10px;font-size:12px;font-weight:600;background:#{background};color:#{color};"
  end
end
