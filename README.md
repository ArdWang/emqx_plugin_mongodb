# emqx_plugin_mongodb

Mongodb plugin for EMQX >= V5.4.0

[中文版](README_CN.md)

## Usage

When using it, be sure to remember that the addition of `.tool-versions` cannot exceed 26 and 3.20.

Replica set name must be "rs0", this is very important, otherwise the plugin will not work.

### Release

The version compiled by `emqx_plugrel/emqx_plugin_mongodb-0.0.1.tar.gz` is not subject to any restrictions or influences.
It will automatically read `{relx, [{release, {emqx_plugin_mongodb, "0.2.4"}]` in `rebar.config`.

```shell
> git clone https://github.com/ArdWang/emqx_plugin_mongodb.git
> cd emqx_plugin_mongodb
> make rel _build/default/emqx_plugrel/emqx_plugin_mongodb-0.0.1.tar.gz
```

### Operation

<img width="1087" height="597" alt="截屏2025-08-29 14 34 29" src="https://github.com/user-attachments/assets/ea8d589a-4f00-41d7-9d20-86c732626d11" />
<img width="1075" height="693" alt="截屏2025-08-29 14 34 47" src="https://github.com/user-attachments/assets/e801c86d-757c-40d3-9ffb-40f65a65ef14" />
<img width="1287" height="896" alt="截屏2025-08-29 14 35 11" src="https://github.com/user-attachments/assets/7a410b6e-17f3-4309-a31b-e0f7f769f754" />

### Config

#### Explain

```shell
> cat priv/emqx_plugin_mongodb.hocon
plugin_mongodb {
  // required
  connection {
    // enum: single | sharded | rs
    // required
    mongo_type = single

    // Following parameters reference https://docs.emqx.com/zh/enterprise/v5.4/admin/api-docs.html#tag/Bridges/paths/~1bridges/post
    // bridge_mongodb.*

    // If mongo type is 'rs', this field required
    replica_set_name = replica_set_name
    // Mongo server address.
    // If  mongo type is 'single', only the first host address is used
    // required
    bootstrap_hosts = ["10.3.64.223:27017", "10.3.64.223:27018", "10.3.64.223:27019"]
    w_mode = unsafe
    // required
    database = "database"
    username = "username"
    password = "password"
    // broker.ssl_client_opts
    ssl {
      enable = false
    }
    topology {
      pool_size = 8
      max_overflow = 0
      local_threshold_ms = 1s
      connect_timeout_ms = 20s
      socket_timeout_ms = 100ms
      server_selection_timeout_ms = 30s
      wait_queue_timeout_ms = 1s
      heartbeat_frequency_ms = 10s
      min_heartbeat_frequency_ms = 1s
    }
    health_check_interval = 32s
  }

  // required
  topics = [
    {
      // Emqx topic pattern.
      // 1. Cannot match the system message;
      // 2. Cannot use filters that start with '+' or '#'.
      filter = "test/#"
      // Unique
      name = emqx_test
      collection = mqtt
    }
  ]
}
```

Some examples in the directory `priv/example/`.

#### Path

- Default path: `emqx/etc/emqx_plugin_mongodb.hocon`
- Custom path: set system environment variable `export EMQX_PLUGIN_MONGODB_CONF="absolute_path"`

Config:

```
plugin_mongodb {
  connection {
    mongo_type = single
    bootstrap_hosts = ["xx.xx.xx.xx:27017"]
    database = "hygro_test"
    username = "xxx"
    password = "xxx"
    topology {
      max_overflow = 10
      connect_timeout_ms = 3s
      server_selection_timeout_ms = 20s
    }
    health_check_interval = 20s
  }

  topics = [
    {
      name = telemetry_topic,
      filter = "/hygro/deviceTelemetry/#",
      collection = "placeholder"
    },
    {
      name = status_topic,
      filter = "hygro/deviceStatus/#",
      collection = "placeholder"
    },
    {
      name: sys_topic,
      filter: "$SYS/#",
      collection = "placeholder"
    }
  ]
}
plugin_mongodb {
  connection {
    mongo_type = rs
    bootstrap_hosts = ["x.x.x.x:27017","x.x.x.x:27018","x.x.x.x:27019"]
    replica_set_name = "rs0"
    database = "xx"
    username = "xx"
    password = "xx"
    topology {
      max_overflow = 10
      #connect_timeout_ms = 3s
      #server_selection_timeout_ms = 20s
      wait_queue_timeout_ms = 1s
      heartbeat_frequency_ms = 10s
    }
    health_check_interval = 20s
  }

  topics = [
    {
      name = telemetry_topic,
      filter = "/hygro/deviceTelemetry/#",
      collection = "placeholder"
    },
    {
      name = status_topic,
      filter = "hygro/deviceStatus/#",
      collection = "placeholder"
    },
    {
      name: sys_topic,
      filter: "$SYS/#",
      collection = "placeholder"
    }
  ]
}

```

#### Data

```js

/hygro/deviceTelemetry/设备名
/hygro/deviceStatus/设备名

{"name":"xxxxb8afea0a","ct":29.9,"ch":69.8,"ctc":1.5,"chc":3.0}

```

```js
telemetry
{
  "_id": 1727334567,
  "time": 1727334567,
  "ct": 33.2,
  "ch": 56.7,
  "chc": 0,
  "ctc": 0
}
```

> **注意**: `time` 字段使用 EMQX 系统时间戳（消息到达时的 Unix 时间戳，秒），不从 payload 中提取。

#### TTL Index (24-Hour Auto Expiration)

The plugin automatically creates a TTL index for each dynamic device collection, causing data to be automatically deleted after 24 hours.

**How it works**:
- When data is first written to a device collection, a TTL index is automatically created on the `time` field
- MongoDB periodically scans and deletes documents where the `time` field exceeds 86,400 seconds (24 hours)
- Rolling window mechanism: the database always retains only the most recent 24 hours of data

**Data volume estimation**:
- Sending one record every 10 seconds → approximately 8,640 records per day
- Total database volume stays around 8,640 records (slight variations due to MongoDB scan delay)

**Notes**:
- The `time` field uses the EMQX system timestamp (Unix timestamp in seconds) when the message arrives, not extracted from payload
- Index name is `ttl_time_24h`; adjust `expireAfterSeconds` to change the expiration period
- If index creation fails (e.g., insufficient permissions), the plugin logs a warning but does not affect data writes
- Manually check indexes in MongoDB: `db.collectionName.getIndexes()`

#### Reload

```shell
// emqx_ctl
> bin/emqx_ctl emqx_plugin_mongodb
emqx_plugin_mongodb reload # Reload topics
> bin/emqx_ctl emqx_plugin_mongodb reload
topics configuration reload complete.
```
