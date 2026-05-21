# Tongyi Worker KV Schema Notes

这份说明基于 [worker.js](/Users/baofuzhang/ppp/Main_ChaoXingReserveSeat/workers/tongyi/src/worker.js) 当前实现整理，目的是给后续“云服务器前端 + 云服务器后端 + Cloudflare KV”方案提供统一数据契约。

## 1. 主要 KV 键

Tongyi Worker 顶部注释和实际代码里使用的核心键如下：

- `schools`
  - 学校 ID 列表
  - 值示例：`["001", "002", "003"]`
- `school:{id}`
  - 单个学校完整配置
- `school:{id}:users`
  - 某学校下的用户 ID 列表
  - 值示例：`["u_001", "u_002"]`
- `school:{id}:user:{userId}`
  - 单个用户完整配置
- `meta:schools:full`
  - 学校列表快照，给管理面板直接显示用
- `school:{id}:users:full`
  - 某学校下用户列表快照，给管理面板直接显示用

额外元数据键：

- `meta:heartbeat:last_ts`
- `meta:heartbeat:last_minute`
- `meta:fallback_trigger:{date}:{schoolId}`

## 2. 学校对象结构

`school:{id}` 的默认结构来自 `defaultSchool(id)`，当前字段如下：

```json
{
  "id": "001",
  "name": "某学校",
  "conflict_group": "",
  "trigger_time": "19:57",
  "endtime": "20:00:40",
  "seat_api_mode": "seat",
  "reserve_next_day": true,
  "enable_slider": false,
  "enable_textclick": false,
  "fidEnc": "",
  "reading_zone_groups": [],
  "repo": "BAOfuZhan/001",
  "dispatch_target": "github",
  "github_token_key": "",
  "github_token": "",
  "server_url": "",
  "server_api_key": "",
  "server_max_concurrency": 13,
  "strategy": {
    "mode": "C",
    "submit_mode": "serial",
    "login_lead_seconds": 18,
    "login_lead_seconds_range": [18, 18],
    "slider_lead_seconds": 10,
    "slider_lead_seconds_range": [10, 10],
    "fast_probe_start_offset_ms": 14,
    "fast_probe_start_range_ms": [14, 14],
    "warm_connection_lead_ms": 2400,
    "pre_fetch_token_ms": 1531,
    "pre_fetch_token_range_ms": [1531, 1531],
    "first_submit_offset_ms": 9,
    "first_submit_offset_range_ms": [9, 9],
    "token_fetch_delay_ms": 45,
    "token_fetch_timeout_ms": 2830,
    "fast_probe_timeout_ms": 2830,
    "first_token_date_mode": "submit_date",
    "burst_offsets_ms": [120, 420, 820],
    "burst_jitter_range_ms": [0, 0]
  }
}
```

和“用户改时间段”直接相关的字段不多，主要是：

- `id`
- `name`
- `fidEnc`
- `reading_zone_groups`
- `dispatch_target`
- `server_url`
- `strategy`
  - `login_lead_seconds_range` 是提前登录秒数随机范围。tongyi 派发用户时会在该闭区间内为每个用户生成 `login_lead_seconds`，并在范围容量足够时尽量避免同一批用户重复。
  - `slider_lead_seconds_range` 是提前滑块秒数随机范围。tongyi 派发用户时会在该闭区间内为每个用户生成 `slider_lead_seconds`，并在范围容量足够时尽量避免同一批用户重复。

## 3. 用户对象结构

`school:{id}:user:{userId}` 的默认结构来自 `defaultUser(id)`：

```json
{
  "id": "u_001",
  "phone": "13800000000",
  "username": "张三",
  "password": "******",
  "remark": "",
  "status": "active",
  "schedule": {
    "Monday": {
      "enabled": false,
      "slots": [
        {
          "roomid": "",
          "seatid": "",
          "times": "",
          "seatPageId": "",
          "fidEnc": ""
        }
      ]
    }
  }
}
```

说明：

- `phone` 是登录账号
- `username` 更像昵称/显示名称
- `password` 在 Worker 里原样存储，管理端读取时会遮罩显示
- `status` 当前默认值是 `active`
- 你真正要让用户编辑的核心字段是 `schedule`

## 4. schedule 结构

### 4.1 Worker 实际保存格式

KV 中最终保存的是“按星期拆开的周计划对象”：

```json
{
  "Monday": {
    "enabled": true,
    "slots": [
      {
        "roomid": "13484",
        "seatid": "356,357",
        "times": "09:00-23:00",
        "seatPageId": "13484",
        "fidEnc": "4a18e12602b24c8c"
      }
    ]
  },
  "Tuesday": {
    "enabled": false,
    "slots": [
      {
        "roomid": "",
        "seatid": "",
        "times": "",
        "seatPageId": "",
        "fidEnc": ""
      }
    ]
  }
}
```

字段说明：

- `enabled`
  - 该天是否启用
- `slots`
  - 最多可有多个时段/多个阅览室配置
- `roomid`
  - 阅览室或区域 ID
- `seatid`
  - Worker 表单保存时是字符串
  - 多个座位会被拼成逗号分隔字符串，如 `"356,357"`
- `times`
  - 字符串，如 `"09:00-23:00"`
- `seatPageId`
  - 通常等于 `roomid`
- `fidEnc`
  - 学校或区域相关的加密字段

### 4.2 管理面板兼容的 JSON 映射格式

Tongyi 的管理端还支持一种更适合外部系统传入的数组格式，代码里由 `parseScheduleJsonMapping()` 转成上面的周计划结构：

```json
[
  {
    "times": ["09:00", "23:00"],
    "roomid": "13484",
    "seatid": ["356", "357"],
    "seatPageId": "13484",
    "fidEnc": "4a18e12602b24c8c",
    "daysofweek": ["Monday", "Tuesday"]
  }
]
```

这对你后面做云服务器前端很有用，因为前端表单往往更容易提交这种数组结构。

建议：

- 前端/后端内部先使用这类“数组映射格式”
- 最终写入 Cloudflare KV 前，再转换成 Tongyi Worker 真实使用的 `schedule` 周计划结构

## 5. 如果云服务器直接写 KV，要同步哪些键

这是最关键的一点。

Tongyi Worker 在保存用户时，不只是写：

- `school:{id}:user:{userId}`

还会同步更新：

- `school:{id}:users`
- `school:{id}:users:full`
- `meta:schools:full`

因此，如果你的云服务器后端绕过 Worker，直接调用 Cloudflare KV API，那么至少要保证这些内容一致：

### 5.1 修改单个用户 schedule

至少同步：

- 更新 `school:{id}:user:{userId}`
- 更新 `school:{id}:users:full` 中对应用户对象

### 5.2 新增用户

至少同步：

- 新增 `school:{id}:user:{userId}`
- 更新 `school:{id}:users`
- 更新 `school:{id}:users:full`
- 更新 `meta:schools:full` 中对应学校的 `userCount`

### 5.3 删除用户

至少同步：

- 删除 `school:{id}:user:{userId}`
- 更新 `school:{id}:users`
- 更新 `school:{id}:users:full`
- 更新 `meta:schools:full` 中对应学校的 `userCount`

## 6. 给云服务器前后端的推荐接口契约

如果你只准备先做“用户登录并修改时间段”，建议后端接口不要直接暴露 Tongyi 的全量学校对象，而是先提供一个更聚焦的接口：

- `POST /api/login`
- `GET /api/me`
- `GET /api/me/schedule`
- `PUT /api/me/schedule`
- `GET /api/schools/:schoolId/reading-zones`

其中：

- `GET /api/me/schedule`
  - 返回“数组映射格式”
- `PUT /api/me/schedule`
  - 前端提交“数组映射格式”
- 后端负责把它转换成 Tongyi Worker 所需的周计划 `schedule`
- 后端写回：
  - `school:{id}:user:{userId}`
  - `school:{id}:users:full`

## 7. 第一版落地建议

为了降低复杂度，第一版建议只支持：

- 用户登录
- 读取本人时间段配置
- 修改本人时间段配置

暂时不要让前端直接修改：

- 学校策略
- `github_token_key`
- `dispatch_target`
- `server_url`
- `repo`

这些字段继续由 Tongyi 管理端维护更稳。

## 8. 结论

后续你的“云服务器前端 + 云服务器后端 + Cloudflare KV”方案，最好遵循下面这条原则：

- 前端编辑：使用简单的数组映射格式
- 后端落 KV：转换成 Tongyi Worker 的周计划 `schedule` 结构
- 后端写入时：同时维护用户主键和用户快照键

这样能保证：

- 你的新前端易开发
- Tongyi 原管理面板不被破坏
- Worker 定时分发逻辑还能继续吃到同一份数据
