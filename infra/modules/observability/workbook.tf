# The monitoring workbook (plan §5 "Running and watching it"): one page for the live path, phone →
# ingest → Event Hubs → processor → PostgreSQL → read API, plus the finalize job and its queue.
# Log tiles query the Log Analytics workspace (App Insights data lands there as App* tables); metric
# tiles read Azure Monitor platform metrics, which are free and need no diagnostic settings.

locals {
  processor_name = basename(var.processor_app_id)
  read_api_name  = basename(var.read_api_app_id)
  finalize_name  = basename(var.finalize_job_id)

  # Every tile follows the time range picked at the top.
  time = { timeContextFromParameter = "TimeRange", timeContext = { durationMs = 0 } }

  # The environment sends logs straight to the workspace (log_analytics_workspace_id in the compute
  # module), so console lines are in the _CL table. ContainerJobName_s appears only after a job has
  # logged, hence column_ifexists.
  processor_lines = <<-KQL
    ContainerAppConsoleLogs_CL
    | where ContainerAppName_s == "${local.processor_name}"
  KQL

  # One line per committed batch (services/processor/roadride/stream.py):
  # "<date> <time> INFO roadride.stream partition=0 events=12 seq=345 lag_s=0.8 new=11 duplicate=1"
  batch_lines = <<-KQL
    ${trimspace(local.processor_lines)}
    | where Log_s contains_cs " lag_s="
    | extend Partition = strcat("partition ", extract(@" partition=(\S+)", 1, Log_s)),
        Events = toint(extract(@" events=([0-9]+)", 1, Log_s)),
        Seq = tolong(extract(@" seq=([0-9]+)", 1, Log_s)),
        LagS = todouble(extract(@" lag_s=([0-9.]+)", 1, Log_s))
    | where isnotnull(Events)
  KQL

  # Log format of the processor, the jobs and the read API: "<date> <time> LEVEL logger message".
  level = <<-KQL
    extract(@"^\S+ \S+ (DEBUG|INFO|WARNING|ERROR|CRITICAL) ", 1, Log_s)
  KQL

  queries = {
    ingest_requests = {
      title = "Ingest requests by status code"
      viz   = "timechart"
      query = <<-KQL
        AppRequests
        | where AppRoleName =~ "${var.ingest_function_name}"
        | summarize Requests = count() by bin(TimeGenerated, {TimeRange:grain}), ResultCode
      KQL
    }
    ingest_summary = {
      title = "Ingest requests per route and status"
      viz   = "table"
      query = <<-KQL
        AppRequests
        | where AppRoleName =~ "${var.ingest_function_name}"
        | summarize Requests = count(), P95ms = round(percentile(DurationMs, 95)) by Function = Name, ResultCode
        | order by Requests desc
      KQL
    }
    # The function logs "<status> <route> <detail>" for every response (services/ingest/function_app.py).
    ingest_rejections = {
      title = "Latest ingest rejections, warnings and errors"
      viz   = "table"
      query = <<-KQL
        union isfuzzy=true
          (AppTraces
            | where AppRoleName =~ "${var.ingest_function_name}"
            | where SeverityLevel >= 2 or Message matches regex @"^[45][0-9][0-9] "
            | project TimeGenerated, SeverityLevel, Message),
          (AppExceptions
            | where AppRoleName =~ "${var.ingest_function_name}"
            | project TimeGenerated, SeverityLevel, Message = strcat(ExceptionType, ": ", OuterMessage)),
          (datatable(TimeGenerated: datetime, SeverityLevel: int, Message: string) [])
        | top 50 by TimeGenerated desc
      KQL
    }
    processor_lag = {
      title = "Processor commit lag, seconds (now minus Event Hubs enqueue time of the batch's last event)"
      viz   = "timechart"
      query = <<-KQL
        ${trimspace(local.batch_lines)}
        | summarize MaxLagS = max(LagS) by bin(TimeGenerated, {TimeRange:grain}), Partition
      KQL
    }
    processor_events = {
      title = "Processor events per minute, by outcome (dropped_* counts parts dropped from an event)"
      viz   = "timechart"
      query = <<-KQL
        ${trimspace(local.batch_lines)}
        | extend Outcomes = extract(@" lag_s=\S+ (.*)$", 1, Log_s)
        | mv-expand Pair = extract_all(@"([a-z_]+)=([0-9]+)", Outcomes)
        | summarize Events = sum(toint(Pair[1])) by bin(TimeGenerated, {TimeRange:grain}), Outcome = tostring(Pair[0])
        | extend EventsPerMinute = round(Events / ({TimeRange:grain} / 1m), 1)
        | project TimeGenerated, Outcome, EventsPerMinute
      KQL
    }
    processor_partitions = {
      title = "Last committed batch per partition"
      viz   = "table"
      query = <<-KQL
        ${trimspace(local.batch_lines)}
        | summarize arg_max(TimeGenerated, Seq, LagS) by Partition
        | project Partition, LastCommit = TimeGenerated, Seq, LagS, QuietFor = now() - TimeGenerated
        | order by Partition asc
      KQL
    }
    # Gauge from the processor's Application Insights exporter (roadride/telemetry.py). Unlike the log
    # lines, it keeps rising while the processor is stuck. Empty until a processor build exports it.
    processor_lag_metric = {
      title = "Processor lag metric roadride.processor.lag, seconds (0 when caught up)"
      viz   = "timechart"
      query = <<-KQL
        union isfuzzy=true
          (AppMetrics
            | where Name == "roadride.processor.lag"
            | project TimeGenerated, Partition = strcat("partition ", tostring(Properties.partition_id)), LagS = Max),
          (datatable(TimeGenerated: datetime, Partition: string, LagS: real) [])
        | summarize MaxLagS = max(LagS) by bin(TimeGenerated, {TimeRange:grain}), Partition
      KQL
    }
    # A process start logs "starting from {...}": more than one per deploy means restarts.
    processor_problems = {
      title = "Processor warnings, errors and process starts"
      viz   = "barchart"
      query = <<-KQL
        ${trimspace(local.processor_lines)}
        | extend Level = ${trimspace(local.level)}
        | extend Kind = iff(Log_s contains_cs " roadride.stream starting from ", "process start", Level)
        | where Kind in ("process start", "WARNING", "ERROR", "CRITICAL")
        | summarize Lines = count() by bin(TimeGenerated, {TimeRange:grain}), Kind
      KQL
    }
    processor_errors = {
      title = "Latest processor warnings and errors"
      viz   = "table"
      query = <<-KQL
        ${trimspace(local.processor_lines)}
        | extend Level = ${trimspace(local.level)}
        | where Level in ("WARNING", "ERROR", "CRITICAL") or Log_s startswith "Traceback" or Log_s matches regex @"^[A-Za-z_.]+(Error|Exception)\b"
        | project TimeGenerated, Level, Log_s
        | top 50 by TimeGenerated desc
      KQL
    }
    # Lines from services/processor/roadride/ready.py (processor) and finalize.py (job).
    finalize_outcomes = {
      title = "Trips queued and finalize outcomes"
      viz   = "barchart"
      query = <<-KQL
        ContainerAppConsoleLogs_CL
        | extend Job = column_ifexists("ContainerJobName_s", "")
        | where Job == "${local.finalize_name}" or ContainerAppName_s == "${local.processor_name}"
        | extend Queued = extract(@" session ready sent for (.*)$", 1, Log_s)
        | extend Outcome = case(
            isnotempty(Queued), "queued",
            Log_s contains_cs " roadride.finalize finalized ", "finalized",
            Log_s contains_cs "finalize failed (delivery", "failed, retried",
            Log_s contains_cs "dead-lettering message: ", "dead-lettered",
            "")
        | where isnotempty(Outcome)
        | extend Trips = iff(Outcome == "queued", array_length(split(Queued, ", ")), long(1))
        | summarize Trips = sum(Trips) by bin(TimeGenerated, {TimeRange:grain}), Outcome
      KQL
    }
    # The data-quality status finalize gives each trip (summary line "... quality=<status>").
    finalize_quality = {
      title = "Finalized trips by data quality"
      viz   = "piechart"
      query = <<-KQL
        ContainerAppConsoleLogs_CL
        | where column_ifexists("ContainerJobName_s", "") == "${local.finalize_name}"
        | where Log_s contains_cs " roadride.finalize finalized "
        | summarize Trips = count() by Quality = extract(@" quality=(\S+)", 1, Log_s)
      KQL
    }
    finalize_log = {
      title = "Latest finalize runs, failures and dead letters"
      viz   = "table"
      query = <<-KQL
        ContainerAppConsoleLogs_CL
        | where column_ifexists("ContainerJobName_s", "") == "${local.finalize_name}"
        | extend Level = ${trimspace(local.level)}
        | where Level in ("WARNING", "ERROR", "CRITICAL") or Log_s contains_cs " roadride.finalize finalized "
        | extend Session = extract(@" finalized (\S+) ", 1, Log_s),
            Detail = coalesce(extract(@" finalized \S+ (.*)$", 1, Log_s), extract(@" roadride\.\S+ (.*)$", 1, Log_s), Log_s)
        | project TimeGenerated, Level, Session, Detail
        | top 50 by TimeGenerated desc
      KQL
    }
    read_api_errors = {
      title = "Latest read API errors"
      viz   = "table"
      query = <<-KQL
        ContainerAppConsoleLogs_CL
        | where ContainerAppName_s == "${local.read_api_name}"
        | extend Level = ${trimspace(local.level)}
        | where Level in ("ERROR", "CRITICAL") or Log_s startswith "Traceback"
        | project TimeGenerated, Level, Log_s
        | top 50 by TimeGenerated desc
      KQL
    }
    # Kubernetes-style events from the platform: crash loops, failed image pulls, failed probes.
    platform_warnings = {
      title = "Container Apps platform warnings (crashes, back-offs, failed pulls)"
      viz   = "table"
      query = <<-KQL
        ContainerAppSystemLogs_CL
        | extend Source = coalesce(column_ifexists("ContainerAppName_s", ""), column_ifexists("JobName_s", ""))
        | where Source in ("${local.processor_name}", "${local.read_api_name}", "${local.finalize_name}")
        | extend Type = column_ifexists("Type_s", ""), Reason = column_ifexists("Reason_s", "")
        | where Type !~ "Normal"
        | project TimeGenerated, Source, Type, Reason, Log_s
        | top 50 by TimeGenerated desc
      KQL
    }
  }

  # Aggregation codes in workbook metric items: 1 sum, 3 max, 4 average.
  metric_charts = {
    eventhub_messages = {
      title    = "Event Hubs messages in and out (hub ${var.eventhub_name})"
      type     = "microsoft.eventhub/namespaces"
      resource = var.eventhub_namespace_id
      filters  = [{ id = "1", key = "EntityName", operator = 0, values = [var.eventhub_name] }]
      metrics  = [{ name = "-IncomingMessages", agg = 1 }, { name = "-OutgoingMessages", agg = 1 }]
    }
    eventhub_errors = {
      title    = "Event Hubs throttled requests and errors"
      type     = "microsoft.eventhub/namespaces"
      resource = var.eventhub_namespace_id
      metrics  = [{ name = "-ThrottledRequests", agg = 1 }, { name = "-ServerErrors", agg = 1 }, { name = "-UserErrors", agg = 1 }]
    }
    processor_restarts = {
      title    = "Processor replica restarts (cumulative)"
      type     = "microsoft.app/containerapps"
      resource = var.processor_app_id
      metrics  = [{ name = "-RestartCount", agg = 3 }]
    }
    finalize_executions = {
      title    = "Finalize job executions by state"
      type     = "microsoft.app/jobs"
      resource = var.finalize_job_id
      metrics  = [{ name = "-Executions", agg = 1, split = "state" }]
    }
    queue_depth = {
      title    = "Queue ${var.queue_name}: messages waiting and dead-lettered"
      type     = "microsoft.servicebus/namespaces"
      resource = var.servicebus_namespace_id
      filters  = [{ id = "1", key = "EntityName", operator = 0, values = [var.queue_name] }]
      metrics  = [{ name = "-ActiveMessages", agg = 3 }, { name = "-DeadletteredMessages", agg = 3 }]
    }
    queue_flow = {
      title    = "Queue ${var.queue_name}: sent, completed, abandoned"
      type     = "microsoft.servicebus/namespaces"
      resource = var.servicebus_namespace_id
      filters  = [{ id = "1", key = "EntityName", operator = 0, values = [var.queue_name] }]
      metrics  = [{ name = "-IncomingMessages", agg = 1 }, { name = "-CompleteMessage", agg = 1 }, { name = "-AbandonMessage", agg = 1 }]
    }
    # Metric ids carry the category for PostgreSQL, as in Microsoft's own PostgreSQL workbooks.
    postgres_cpu = {
      title    = "PostgreSQL CPU % and memory % (max)"
      type     = "microsoft.dbforpostgresql/flexibleservers"
      resource = var.postgres_server_id
      metrics  = [{ name = "Saturation-cpu_percent", agg = 3 }, { name = "Saturation-memory_percent", agg = 3 }]
    }
    # B1ms is burstable: once the credits run out, CPU is held at the base rate.
    postgres_credits = {
      title    = "PostgreSQL CPU credits remaining"
      type     = "microsoft.dbforpostgresql/flexibleservers"
      resource = var.postgres_server_id
      metrics  = [{ name = "Saturation-cpu_credits_remaining", agg = 4 }]
    }
    postgres_storage = {
      title    = "PostgreSQL storage % (32 GB, no auto-grow)"
      type     = "microsoft.dbforpostgresql/flexibleservers"
      resource = var.postgres_server_id
      metrics  = [{ name = "Saturation-storage_percent", agg = 3 }]
    }
    postgres_connections = {
      title    = "PostgreSQL active and failed connections"
      type     = "microsoft.dbforpostgresql/flexibleservers"
      resource = var.postgres_server_id
      metrics  = [{ name = "Traffic-active_connections", agg = 3 }, { name = "Errors-connections_failed", agg = 1 }]
    }
    read_api_requests = {
      title    = "Read API requests by status class"
      type     = "microsoft.app/containerapps"
      resource = var.read_api_app_id
      metrics  = [{ name = "-Requests", agg = 1, split = "statusCodeCategory" }]
    }
    read_api_latency = {
      title    = "Read API average response time, ms"
      type     = "microsoft.app/containerapps"
      resource = var.read_api_app_id
      metrics  = [{ name = "-ResponseTime", agg = 4 }]
    }
    read_api_restarts = {
      title    = "Read API replica restarts (cumulative)"
      type     = "microsoft.app/containerapps"
      resource = var.read_api_app_id
      metrics  = [{ name = "-RestartCount", agg = 3 }]
    }
  }

  kql_items = {
    for k, q in local.queries : k => {
      type = 3
      name = k
      content = merge(local.time, {
        version                 = "KqlItem/1.0"
        title                   = q.title
        query                   = trimspace(q.query)
        size                    = 0
        queryType               = 0
        resourceType            = "microsoft.operationalinsights/workspaces"
        crossComponentResources = [azurerm_log_analytics_workspace.this.id]
        visualization           = q.viz
      })
    }
  }

  metric_items = {
    for k, m in local.metric_charts : k => {
      type = 10
      name = k
      content = merge(local.time, {
        version      = "MetricsItem/2.0"
        title        = m.title
        size         = 0
        chartType    = 2 # line
        resourceType = m.type
        metricScope  = 0
        resourceIds  = [m.resource]
        filters      = try(m.filters, [])
        gridSettings = { rowLimit = 10000 }
        metrics = [for x in m.metrics : {
          namespace   = m.type
          metric      = "${m.type}-${x.name}"
          aggregation = x.agg
          splitBy     = try(x.split, null)
        }]
      })
    }
  }

  tiles = merge(local.kql_items, local.metric_items)

  # Layout: a heading per hop, then its tiles side by side (customWidth is a percentage).
  sections = [
    {
      heading = "## Ingest function\nEvery request from the phones. 200 = stored and sent on; 401 = unknown device key; 400/413 = a bad request (the reason is in the log line); 503 = Event Hubs, storage or Key Vault unreachable, the phone retries."
      tiles   = [["ingest_requests", "50"], ["ingest_summary", "50"], ["ingest_rejections", "100"]]
    },
    {
      heading = "## Event Hubs\nIncoming should match the ingest function's 200s; outgoing is the processor reading."
      tiles   = [["eventhub_messages", "50"], ["eventhub_errors", "50"]]
    },
    {
      heading = "## Stream processor\nOne log line per committed batch. Lag above 10 s means the live map is behind; no new lines while phones send means the processor is stuck."
      tiles = [
        ["processor_lag", "50"], ["processor_events", "50"],
        ["processor_partitions", "50"], ["processor_lag_metric", "50"],
        ["processor_problems", "50"], ["processor_restarts", "50"],
        ["processor_errors", "100"],
      ]
    },
    {
      heading = "## Finalize job and the session-ready queue\nThe processor queues a trip when it ends; the job finalizes it. A message is dead-lettered after 5 failed tries, or at once when it can't be finalized (no raw archive, uploaded folders)."
      tiles = [
        ["finalize_outcomes", "50"], ["finalize_executions", "50"],
        ["queue_depth", "50"], ["queue_flow", "50"],
        ["finalize_quality", "33"], ["finalize_log", "67"],
      ]
    },
    {
      heading = "## PostgreSQL"
      tiles = [
        ["postgres_cpu", "50"], ["postgres_credits", "50"],
        ["postgres_storage", "50"], ["postgres_connections", "50"],
      ]
    },
    {
      heading = "## Read API\nWhat the dashboard calls."
      tiles = [
        ["read_api_requests", "50"], ["read_api_latency", "50"],
        ["read_api_restarts", "50"], ["read_api_errors", "50"],
        ["platform_warnings", "100"],
      ]
    },
  ]

  workbook = {
    version = "Notebook/1.0"
    items = concat(
      [
        {
          type    = 1
          name    = "title"
          content = { json = "# Road & Ride: live path\nPhone → ingest function → Event Hubs → stream processor → PostgreSQL → read API, and the finalize job. Plan §5 \"Running and watching it\"." }
        },
        {
          type = 9
          name = "parameters"
          content = {
            version = "KqlParameterItem/1.0"
            style   = "pills"
            parameters = [{
              id         = "d6a1c5a2-1f0e-4d0b-9a77-3c9f3e1b2a10"
              version    = "KqlParameterItem/1.0"
              name       = "TimeRange"
              label      = "Time range"
              type       = 4
              isRequired = true
              value      = { durationMs = 14400000 } # 4 h: a drive and its finalize
              typeSettings = {
                allowCustom      = true
                selectableValues = [for ms in [900000, 3600000, 14400000, 43200000, 86400000, 259200000, 604800000] : { durationMs = ms }]
              }
            }]
          }
        },
      ],
      flatten([
        for i, s in local.sections : concat(
          [{ type = 1, name = "heading-${i}", content = { json = s.heading } }],
          [for t in s.tiles : merge(local.tiles[t[0]], { customWidth = t[1] })],
        )
      ]),
    )
    fallbackResourceIds = [azurerm_log_analytics_workspace.this.id]
    "$schema"           = "https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json"
  }
}

resource "azurerm_application_insights_workbook" "live_path" {
  # Fixed name derived from the resource group, so a re-apply updates the workbook instead of adding one.
  name                = uuidv5("url", "${var.resource_group_id}/workbooks/live-path")
  resource_group_name = var.resource_group_name
  location            = var.location
  display_name        = "Road & Ride: live path"
  source_id           = lower(azurerm_application_insights.this.id)
  data_json           = jsonencode(local.workbook)
  tags                = var.tags
}
