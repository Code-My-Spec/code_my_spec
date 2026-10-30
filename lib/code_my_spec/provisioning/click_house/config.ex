defmodule CodeMySpec.Provisioning.ClickHouse.Config do
  @moduledoc false

  def users do
    """
    <clickhouse>
      <users>
        <default remove="remove"/>
        <cms_admin>
          <networks replace="replace">
            <ip>127.0.0.1</ip>
            <ip>::1</ip>
          </networks>
        </cms_admin>
      </users>
    </clickhouse>
    """
  end

  def server, do: server(:full)

  def server(mode) do
    memory = if mode == :capped, do: 671_088_640, else: 1_073_741_824

    """
    <clickhouse>
      <max_server_memory_usage>#{memory}</max_server_memory_usage>
      <mark_cache_size>67108864</mark_cache_size>
      <uncompressed_cache_size>16777216</uncompressed_cache_size>
      <max_connections>128</max_connections>
      <max_concurrent_queries>16</max_concurrent_queries>
      <logger>
        <level>warning</level>
        <console>true</console>
      </logger>
    </clickhouse>
    """
  end

  def vector do
    ~S"""
    data_dir: /var/lib/vector
    sources:
      containers:
        type: docker_logs
        include_labels: [service]
    transforms:
      otlp:
        type: remap
        inputs: [containers]
        drop_on_error: true
        source: |
          service = string!(.label.service)
          role = string(.label.role) ?? "web"
          message = string!(.message)
          event_time = timestamp!(.timestamp)
          container = string(.container_name) ?? "unknown"
          stream = string(.stream) ?? "stdout"
          . = {
            "resourceLogs": [{
              "resource": {"attributes": [
                {"key": "service.name", "value": {"stringValue": service + "-" + role}},
                {"key": "container.name", "value": {"stringValue": container}}
              ]},
              "scopeLogs": [{
                "scope": {"name": "cms.docker"},
                "logRecords": [{
                  "timeUnixNano": to_string(to_unix_timestamp(event_time, unit: "nanoseconds")),
                  "body": {"stringValue": message},
                  "attributes": [{"key": "log.iostream", "value": {"stringValue": stream}}]
                }]
              }]
            }]
          }
    sinks:
      collector:
        type: http
        inputs: [otlp]
        uri: http://cms-otel-collector:4318/v1/logs
        method: post
        encoding:
          codec: json
        framing:
          method: bytes
        batch:
          max_events: 1
        request:
          headers:
            Content-Type: application/json
        buffer:
          type: disk
          max_size: 268435488
          when_full: block
        healthcheck:
          enabled: false
    """
  end

  def collector do
    ~S"""
    extensions:
      health_check:
        endpoint: 0.0.0.0:13133
      file_storage:
        directory: /var/lib/otelcol/queue
        create_directory: true
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
    processors:
      memory_limiter:
        check_interval: 1s
        limit_mib: 256
        spike_limit_mib: 64
      batch:
        timeout: 5s
        send_batch_size: 1024
        send_batch_max_size: 2048
    exporters:
      clickhouse:
        endpoint: tcp://cms-clickhouse:9000
        database: otel
        username: ${env:CLICKHOUSE_USER}
        password: ${env:CLICKHOUSE_PASSWORD}
        create_schema: false
        ttl: 336h
        logs_table_name: otel_logs
        traces_table_name: otel_traces
        timeout: 10s
        sending_queue:
          enabled: true
          num_consumers: 2
          queue_size: 1000
          storage: file_storage
        retry_on_failure:
          enabled: true
          initial_interval: 5s
          max_interval: 30s
          max_elapsed_time: 0s
    service:
      extensions: [health_check, file_storage]
      pipelines:
        logs:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [clickhouse]
        traces:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [clickhouse]
    """
  end
end
