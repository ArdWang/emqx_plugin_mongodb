# emqx_plugin_mongodb

EMQX >= V5.4.0 MongoDB 插件

[English Version](README.md)

## 使用说明

使用时请注意，`.tool-versions` 版本不能超过 26 和 3.20。

副本集名称必须为 `rs0`，否则插件将无法正常工作。

### 编译发布

编译版本 `emqx_plugrel/emqx_plugin_mongodb-0.0.1.tar.gz` 不受任何限制或影响。
它会自动读取 `rebar.config` 中的 `{relx, [{release, {emqx_plugin_mongodb, "0.2.4"}]`。

```shell
> git clone https://github.com/ArdWang/emqx_plugin_mongodb.git
> cd emqx_plugin_mongodb
> make rel _build/default/emqx_plugrel/emqx_plugin_mongodb-0.0.1.tar.gz
```

### 操作界面

<img width="1087" height="597" alt="截屏2025-08-29 14 34 29" src="https://github.com/user-attachments/assets/ea8d589a-4f00-41d7-9d20-86c732626d11" />
<img width="1075" height="693" alt="截屏2025-08-29 14 34 47" src="https://github.com/user-attachments/assets/e801c86d-757c-40d3-9ffb-40f65a65ef14" />
<img width="1287" height="896" alt="截屏2025-08-29 14 35 11" src="https://github.com/user-attachments/assets/7a410b6e-17f3-4309-a31b-e0f7f769f754" />

### 配置说明

#### 配置参数

```shell
> cat priv/emqx_plugin_mongodb.hocon
plugin_mongodb {
  // 必填
  connection {
    // 枚举: single | sharded | rs
    // 必填
    mongo_type = single

    // 以下参数参考 https://docs.emqx.com/zh/enterprise/v5.4/admin/api-docs.html#tag/Bridges/paths/~1bridges/post
    // bridge_mongodb.*

    // 如果 mongo type 为 'rs'，此字段为必填
    replica_set_name = replica_set_name
    // MongoDB 服务器地址
    // 如果 mongo type 为 'single'，仅使用第一个主机地址
    // 必填
    bootstrap_hosts = ["10.3.64.223:27017", "10.3.64.223:27018", "10.3.64.223:27019"]
    w_mode = unsafe
    // 必填
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

  // 必填
  topics = [
    {
      // EMQX 主题模式
      // 1. 不能匹配系统消息
      // 2. 不能使用以 '+' 或 '#' 开头的过滤器
      filter = "test/#"
      // 唯一标识
      name = emqx_test
      collection = mqtt
    }
  ]
}
```

更多示例请参考 `priv/example/` 目录。

#### 配置文件路径

- 默认路径：`emqx/etc/emqx_plugin_mongodb.hocon`
- 自定义路径：设置系统环境变量 `export EMQX_PLUGIN_MONGODB_CONF="绝对路径"`

配置示例：

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
      filter = "hygro/deviceTelemetry/#",
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
      filter = "hygro/deviceTelemetry/#",
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

#### 数据格式

```js

hygro/deviceStatus/xxxxb8aff43c
hygro/deviceTelemetry/xxxb8aff43c

{"name":"xxxxb8afea0a","ct":29.9,"ch":69.8,"ctc":1.5,"chc":3.0,"time":1718868312}

```

```js
遥测数据 (telemetry)
{
  "_id": 1727334567,
  "name": "xxxb8aff30a",
  "time": 1727334567,
  "ct": 33.2,
  "ch": 56.7,
  "chc": 0,
  "ctc": 0
}

设备状态 (status)
{
    "_id": "xxxaff30a"
    "username": "202412200818",
    "flags":{
    "dup":false,
        "retain": false
},
    "qos":1,
    "topic":"test/t1/mongo",
    "peerhost":"127.0.0.1",
    "publish_reveived_at":1754984956681
}

```

#### 数据容量控制（最多保留 8400 条）

插件会自动为每个动态设备集合创建索引，并在数据超过上限时删除最旧的记录。

**工作原理**：
- 当首次向某个设备集合写入数据时，自动在该集合的 `time` 字段上创建普通索引
- 每次插入新数据后，检查集合文档总数
- 当文档数超过 8,400 条时，按 `_id`（时间戳）升序删除最旧的文档，直到恢复到 8,400 条
- 数据库始终保留最新的 8,400 条记录

**注意事项**：
- `_id` 字段为秒级 Unix 时间戳（数字类型），用于标识新旧数据
- 上限值 `MAX_DOCUMENT_COUNT` 定义在源码 `emqx_plugin_mongodb_connector.erl` 中，可按需修改
- 如果索引创建失败（如权限不足），插件会记录 warning 日志但不影响数据写入
- 手动在 MongoDB 中查看索引：`db.集合名.getIndexes()`

#### 重载配置

```shell
// emqx_ctl
> bin/emqx_ctl emqx_plugin_mongodb
emqx_plugin_mongodb reload # 重载主题配置
> bin/emqx_ctl emqx_plugin_mongodb reload
topics configuration reload complete.
```
